// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IMultiverse } from "./interfaces/IMultiverse.sol";
import { IQueryToken } from "./interfaces/IQueryToken.sol";
import { IQueryTokenizer } from "./interfaces/IQueryTokenizer.sol";
import { ILituusRep } from "./interfaces/ILituusRep.sol";
import { IPermit2 } from "./interfaces/IPermit2.sol";
import { ITokenDeployer } from "./interfaces/ITokenDeployer.sol";
import { PermitSupport } from "./PermitSupport.sol";

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
 *      the price, and a fork's donation: when a universe forks with more tips than its children may carry,
 *      the Multiverse donates the excess to the universe's pool (see donateRep), raising the average for the
 *      tokens about to migrate. The redemption fee is recorded whole, uncapped: the pool average can exceed
 *      half the fork threshold (the average never decays while the threshold can decline), and the oracle
 *      handles that separately.
 *
 *      Query tokens are universe-specific and are NEVER forwarded to the heir: once a universe forks,
 *      minting and redeeming freeze there (the oracle rejects non-current universes) and migration is the
 *      only path to a child. Inside the migration window a holder picks a child: the parent tokens burn,
 *      their share of the pool migrates through the Multiverse as a counted vote for that child, and the
 *      same number of the child's tokens is minted to the holder. Tokens not migrated stay in the parent
 *      with their share of the pool, worthless.
 *
 *      Minting takes the wREP on a plain allowance or through Permit2, and `permitRep` applies an ERC-2612
 *      permit on the wREP, so approving and minting fit in one `multicall` (see PermitSupport).
 */
contract QueryTokenizer is ReentrancyGuard, PermitSupport, IQueryTokenizer {
    using SafeERC20 for ILituusRep;

    /* ========================================== CONSTANTS/IMMUTABLES =========================================== */
    // 1e18 QueryToken wei = the right to create one query (18 decimals).
    uint256 public constant ONE_QUERY = 1e18;
    // Fixed 10% mint premium, applied as ×11/10 (equals the fee controller's max monthly step).
    uint256 public constant PREMIUM_NUMERATOR = 11;
    uint256 public constant PREMIUM_DENOMINATOR = 10;

    // Deploys the per-universe QueryTokens with this contract as owner (the same deployer the Multiverse
    // deploys its wREP vaults through). Kept separate so the token's creation code stays out of this contract.
    ITokenDeployer public immutable TOKEN_DEPLOYER;
    // The Multiverse this tokenizer creates queries in. Bound at construction to the address the Multiverse is
    // about to be deployed to (see Deploy.s.sol).
    IMultiverse public immutable MULTIVERSE;

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
    error ZeroAddress();
    error NotMultiverse();

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
    // Lituus REP the Multiverse added to a universe's pool without minting tokens: a fork's excess tips.
    event PoolDonated(uint248 indexed universeId, uint256 amount);

    /* =============================================== CONSTRUCTOR =============================================== */
    /// @param permit2_ Uniswap's Permit2 (see PermitSupport).
    /// @param tokenDeployer_ The deployer of the QueryTokens.
    /// @param multiverse_ The Multiverse this tokenizer serves, at the address it is about to be deployed to.
    constructor(IPermit2 permit2_, ITokenDeployer tokenDeployer_, IMultiverse multiverse_) PermitSupport(permit2_) {
        if (address(tokenDeployer_) == address(0) || address(multiverse_) == address(0)) revert ZeroAddress();
        TOKEN_DEPLOYER = tokenDeployer_;
        MULTIVERSE = multiverse_;
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
        (uint256 price,) = _mintPrice(universeId);
        return price;
    }

    /// @dev `mintPrice` body, also returning the universe's Lituus REP so `mint` prices and pays with a single
    ///      Multiverse call.
    function _mintPrice(uint248 universeId) internal view returns (uint256, ILituusRep) {
        (uint256 uncappedFee, uint256 cap, ILituusRep repToken) = MULTIVERSE.getMintPricing(universeId);
        uint256 price = uncappedFee * PREMIUM_NUMERATOR / PREMIUM_DENOMINATOR;
        return (price > cap ? cap : price, repToken);
    }

    /* ============================================= CORE ACTIONS =============================================== */
    /// @inheritdoc IQueryTokenizer
    function mint(uint248 universeId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Price first: _mintPrice reverts for a nonexistent or non-current universe, so no QueryToken
        // is ever deployed for an invalid universe. A zero cost is rejected — free tokens would dilute
        // the pool average for every existing holder.
        (uint256 price, ILituusRep repToken) = _mintPrice(universeId);
        uint256 cost = price * amount;
        if (cost == 0) revert ZeroCost();
        _pull(repToken, cost);
        pooledRep[universeId] += cost;

        IQueryToken queryToken = _getOrDeployToken(universeId);
        queryToken.mint(msg.sender, amount * ONE_QUERY);
        emit Minted(msg.sender, universeId, amount, cost);
    }

    /// @inheritdoc IQueryTokenizer
    function redeem(uint248 universeId, string calldata question, uint8 numberOfOutcomes) external nonReentrant {
        (IQueryToken queryToken, uint256 wholeTokensTotalSupply) = _outstandingWholeTokens(universeId);

        // Price of this exact token = the pool average per query.
        uint256 pooledRepTokens = pooledRep[universeId];
        uint256 price = pooledRepTokens / wholeTokensTotalSupply;

        // Reverts with ERC20InsufficientBalance if the caller holds less than one whole token,
        // so no separate balance pre-check is needed.
        queryToken.burn(msg.sender, ONE_QUERY);
        pooledRep[universeId] = pooledRepTokens - price;

        // Push the REP to the oracle, then create the query at exactly `price`, attributed to the redeemer.
        MULTIVERSE.repTokenOf(universeId).safeTransfer(address(MULTIVERSE), price);
        MULTIVERSE.createQueryFromTokenizer(universeId, question, numberOfOutcomes, price, msg.sender);

        emit Redeemed(msg.sender, universeId, price);
    }

    /* ============================================ FORK MIGRATION =============================================== */
    /// @inheritdoc IQueryTokenizer
    function permitRep(uint248 universeId, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        _permit(MULTIVERSE.repTokenOf(universeId), value, deadline, v, r, s);
    }

    /// @inheritdoc IQueryTokenizer
    function migrate(uint248 parentUniverseId, uint256 childOutcome, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        (IQueryToken parentToken, uint256 wholeTokensTotalSupply) = _outstandingWholeTokens(parentUniverseId);

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
        (uint248 childUniverseId, uint256 childShares) = MULTIVERSE.migrate(parentUniverseId, childOutcome, migratedRep);
        pooledRep[childUniverseId] += childShares;

        IQueryToken childToken = _getOrDeployToken(childUniverseId);
        childToken.mint(msg.sender, amount * ONE_QUERY);
        emit QueryTokensMigrated(msg.sender, parentUniverseId, childUniverseId, amount, migratedRep);
    }

    /// @inheritdoc IQueryTokenizer
    function donateRep(uint248 universeId, uint256 amount) external returns (bool accepted) {
        // The credit below runs ahead of the REP, so only the caller trusted to send it may ask for one.
        if (msg.sender != address(MULTIVERSE)) revert NotMultiverse();

        // Refused without a whole token outstanding: nothing could ever carry the REP out of the pool. Nothing
        // is booked, and the Multiverse keeps the REP.
        (, uint256 wholeTokens) = _wholeTokens(universeId);
        if (wholeTokens == 0) return false;

        // Accepted. The pool is credited before the REP arrives: the Multiverse transfers `amount` as soon as
        // this returns, in the same transaction (see ForkLib._capCarriedTips). The two cannot come apart:
        // - nothing runs between the credit and the transfer but the vault's own transfer, which calls no one,
        //   so nobody can act on a pool that is ahead of the balance;
        // - if the transfer failed, the whole transaction would revert, and this credit with it.
        pooledRep[universeId] += amount;
        emit PoolDonated(universeId, amount);
        return true;
    }

    /* ================================================ INTERNALS ================================================ */
    /// @dev The universe's query token and how many whole tokens of it are outstanding. Both are zero for a
    ///      universe whose token was never deployed.
    function _wholeTokens(uint248 universeId) internal view returns (IQueryToken queryToken, uint256 wholeTokens) {
        queryToken = token[universeId];
        if (address(queryToken) != address(0)) wholeTokens = queryToken.totalSupply() / ONE_QUERY;
    }

    /// @dev _wholeTokens for the paths that spend a token: reverts if the token was never deployed or no whole
    ///      token is outstanding.
    function _outstandingWholeTokens(uint248 universeId)
        internal
        view
        returns (IQueryToken queryToken, uint256 wholeTokens)
    {
        (queryToken, wholeTokens) = _wholeTokens(universeId);
        if (address(queryToken) == address(0)) revert QueryTokenNotExisting();
        if (wholeTokens == 0) revert NoWholeTokens();
    }

    function _getOrDeployToken(uint248 universeId) internal returns (IQueryToken queryToken) {
        queryToken = token[universeId];
        if (address(queryToken) == address(0)) {
            // Named after the universe's Zoltar REP token, like its wREP vault.
            queryToken = TOKEN_DEPLOYER.deployQueryToken(address(MULTIVERSE.ZOLTAR().getRepToken(universeId)));
            token[universeId] = queryToken;
            emit QueryTokenDeployed(universeId, address(queryToken));
        }
    }
}
