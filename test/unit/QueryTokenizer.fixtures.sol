// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { QueryToken } from "src/QueryToken.sol";
import { QueryTokenizer } from "src/QueryTokenizer.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { IMultiverse } from "src/interfaces/IMultiverse.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";
import { IQueryToken } from "src/interfaces/IQueryToken.sol";
import { MultiverseFixtures } from "./Multiverse.fixtures.sol";

/// @notice Wired tokenizer fixture: the funded functional layer with a REAL QueryTokenizer connected
///         to the Multiverse (mirroring script/Deploy.s.sol), plus tokenizer approvals and the
///         mint/redeem step helpers used by the tokenizer suites.
/// @dev The tokenizer is deployed inside `_deployMultiverse` (it must exist before the Multiverse,
///      whose constructor takes its address) and wired via `_afterProtocolDeploy`
///      (`setMultiverse` — the deployer is this test contract). The funded actors additionally
///      approve the tokenizer on the genesis Lituus REP, since `mint` pulls wREP from the caller.
abstract contract QueryTokenizerFixtures is MultiverseFixtures {
    // The funded fixture holds 3200 underlying (3 × 1000 wrapped by the actors plus the 200 top-up
    // that aligns the fee with the cap grid), so MockZoltar's fork threshold is 3200 / 20 = 160 REP.
    // Half of it — the cap on both the tokenizer's mint price and the direct-path query fee — is
    // the single derivation every cap assertion builds on.
    uint256 internal constant HALF_FORK_THRESHOLD = 32 ether;

    QueryTokenizer internal tokenizer;

    function setUp() public virtual override {
        super.setUp();

        _approveTokenizer(user);
        _approveTokenizer(bystander);
        _approveTokenizer(challenger);
    }

    /// @dev Deploys the real tokenizer first, then the Multiverse pointing at it (Deploy.s.sol order).
    function _deployMultiverse(IQueryFeeController controller) internal override returns (Multiverse) {
        tokenizer = new QueryTokenizer();
        return new Multiverse(
            zoltar, GENESIS_UID, controller, address(tokenizer), MIGRATION_DURATION, REPORTING_PERIOD, APPEAL_PERIOD
        );
    }

    /// @dev Completes the deploy wiring: the tokenizer learns the Multiverse address (once).
    function _afterProtocolDeploy() internal override {
        tokenizer.setMultiverse(IMultiverse(address(multiverse)));
    }

    /// @dev Approves the tokenizer to pull the account's genesis Lituus REP (mint's payment path).
    function _approveTokenizer(address account) internal {
        vm.prank(account);
        genesisRep.approve(address(tokenizer), type(uint256).max);
    }

    /// @dev Mint fixture: `account` mints `amount` whole Query Tokens, asserting the cost
    ///      (mintPrice × amount), the Minted event, the wREP movement (account → tokenizer), the
    ///      pooledRep accounting, and the QueryToken balance/supply deltas.
    /// @return cost The Lituus REP the mint pulled.
    function _mintTokens(address account, uint256 amount) internal returns (uint256 cost) {
        cost = tokenizer.mintPrice(GENESIS_UID) * amount;
        uint256 accountRepBefore = genesisRep.balanceOf(account);
        uint256 tokenizerRepBefore = genesisRep.balanceOf(address(tokenizer));
        uint256 pooledBefore = tokenizer.pooledRep(GENESIS_UID);
        IQueryToken tokenBefore = tokenizer.token(GENESIS_UID);
        uint256 balanceBefore = address(tokenBefore) == address(0) ? 0 : tokenBefore.balanceOf(account);
        uint256 supplyBefore = address(tokenBefore) == address(0) ? 0 : tokenBefore.totalSupply();

        vm.expectEmit(true, true, true, true, address(tokenizer));
        emit QueryTokenizer.Minted(account, GENESIS_UID, amount, cost);
        vm.prank(account);
        tokenizer.mint(GENESIS_UID, amount);

        IQueryToken queryToken = tokenizer.token(GENESIS_UID);
        assertTrue(address(queryToken) != address(0));
        uint256 mintedWei = amount * tokenizer.ONE_QUERY();
        assertEq(queryToken.balanceOf(account), balanceBefore + mintedWei);
        assertEq(queryToken.totalSupply(), supplyBefore + mintedWei);
        assertEq(genesisRep.balanceOf(account), accountRepBefore - cost);
        assertEq(genesisRep.balanceOf(address(tokenizer)), tokenizerRepBefore + cost);
        assertEq(tokenizer.pooledRep(GENESIS_UID), pooledBefore + cost);
    }

    /// @dev Redeem fixture: `account` redeems one whole Query Token into a default query, asserting
    ///      the pool-average price (floor(pooledRep / wholeSupply)), the burn, the pool decrement
    ///      (dust stays pooled), the wREP push to the Multiverse, the created query record (fee =
    ///      price, creator = redeemer), and the QueryCreated + Redeemed events.
    /// @return price The pool-average fee the redemption paid.
    /// @return queryId The id of the query the redemption created.
    function _redeemToken(address account) internal returns (uint256 price, uint256 queryId) {
        return _redeemTokenIn(GENESIS_UID, account);
    }

    /// @dev `_redeemToken` in any universe, in that universe's wREP.
    function _redeemTokenIn(uint248 universeId, address account) internal returns (uint256 price, uint256 queryId) {
        ILituusRep repToken = multiverse.repTokenOf(universeId);
        IQueryToken queryToken = tokenizer.token(universeId);
        uint256 wholeSupply = queryToken.totalSupply() / tokenizer.ONE_QUERY();
        uint256 pooledBefore = tokenizer.pooledRep(universeId);
        price = pooledBefore / wholeSupply;
        queryId = multiverse.queryCount();

        uint256 balanceBefore = queryToken.balanceOf(account);
        uint256 tokenizerRepBefore = repToken.balanceOf(address(tokenizer));
        uint256 multiverseRepBefore = repToken.balanceOf(address(multiverse));

        // Emission order inside redeem(): the Multiverse emits QueryCreated, then the tokenizer
        // emits Redeemed.
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryCreated(account, queryId, universeId, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        vm.expectEmit(true, true, true, true, address(tokenizer));
        emit QueryTokenizer.Redeemed(account, universeId, price);
        vm.prank(account);
        tokenizer.redeem(universeId, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        assertEq(queryToken.balanceOf(account), balanceBefore - tokenizer.ONE_QUERY());
        assertEq(tokenizer.pooledRep(universeId), pooledBefore - price);
        assertEq(repToken.balanceOf(address(tokenizer)), tokenizerRepBefore - price);
        assertEq(repToken.balanceOf(address(multiverse)), multiverseRepBefore + price);

        assertEq(multiverse.queryCount(), queryId + 1);
        (uint8 numberOfOutcomes, uint248 originUniverse, uint256 fee, string memory question,) =
            multiverse.queries(queryId);
        assertEq(numberOfOutcomes, DEFAULT_NUMBER_OF_OUTCOMES);
        assertEq(originUniverse, universeId);
        assertEq(fee, price);
        assertEq(question, DEFAULT_QUESTION);

        ResolutionView memory r = _resolutionIn(universeId, queryId);
        uint48 queryCreateTime = r.queryCreateTime;
        uint256 outcome = r.outcome;
        assertEq(queryCreateTime, uint48(vm.getBlockTimestamp()));
        assertEq(outcome, multiverse.UNRESOLVED());
    }

    /// @dev Migration fixture: `account` migrates `amount` whole genesis Query Tokens into the child of
    ///      `outcome`, asserting what leaves the parent pool (floor(pooledRep / wholeSupply) × amount) and the
    ///      tokenizer's parent wREP, the parent burn, the child wREP arriving at the parent's rate and being
    ///      pooled, the child token balance/supply, the parent's and the child's migration counters, and the
    ///      Migrated event.
    /// @return migratedRep The parent wREP the migration took out of the pool.
    /// @return childShares The child wREP it put into the child's pool.
    function _migrateTokens(address account, uint256 outcome, uint256 amount)
        internal
        returns (uint256 migratedRep, uint256 childShares)
    {
        uint248 childId = _childId(GENESIS_UID, outcome);
        ILituusRep childRep = multiverse.repTokenOf(childId);
        IQueryToken parentToken = tokenizer.token(GENESIS_UID);
        uint256 wholeSupply = parentToken.totalSupply() / tokenizer.ONE_QUERY();
        uint256 pooledBefore = tokenizer.pooledRep(GENESIS_UID);
        migratedRep = pooledBefore / wholeSupply * amount;
        uint256 assets = genesisRep.convertToAssets(migratedRep);
        childShares = childRep.convertToShares(assets);

        uint256 parentBalanceBefore = parentToken.balanceOf(account);
        uint256 parentSupplyBefore = parentToken.totalSupply();
        uint256 tokenizerParentRepBefore = genesisRep.balanceOf(address(tokenizer));
        uint256 tokenizerChildRepBefore = childRep.balanceOf(address(tokenizer));
        uint256 childPooledBefore = tokenizer.pooledRep(childId);
        IQueryToken childTokenBefore = tokenizer.token(childId);
        uint256 childBalanceBefore = address(childTokenBefore) == address(0) ? 0 : childTokenBefore.balanceOf(account);
        uint256 childSupplyBefore = address(childTokenBefore) == address(0) ? 0 : childTokenBefore.totalSupply();
        uint128 migratedInBefore = _totalMigratedIn(childId);
        uint128 migratedOutBefore = _totalMigratedOut(GENESIS_UID);

        vm.expectEmit(true, true, true, true, address(tokenizer));
        emit QueryTokenizer.Migrated(account, GENESIS_UID, childId, amount, migratedRep);
        vm.prank(account);
        tokenizer.migrate(GENESIS_UID, outcome, amount);

        uint256 migratedWei = amount * tokenizer.ONE_QUERY();
        assertEq(parentToken.balanceOf(account), parentBalanceBefore - migratedWei);
        assertEq(parentToken.totalSupply(), parentSupplyBefore - migratedWei);
        assertEq(tokenizer.pooledRep(GENESIS_UID), pooledBefore - migratedRep);
        assertEq(genesisRep.balanceOf(address(tokenizer)), tokenizerParentRepBefore - migratedRep);

        IQueryToken childToken = tokenizer.token(childId);
        assertTrue(address(childToken) != address(0));
        assertEq(childToken.balanceOf(account), childBalanceBefore + migratedWei);
        assertEq(childToken.totalSupply(), childSupplyBefore + migratedWei);
        assertEq(childRep.balanceOf(address(tokenizer)), tokenizerChildRepBefore + childShares);
        assertEq(tokenizer.pooledRep(childId), childPooledBefore + childShares);

        assertEq(_totalMigratedIn(childId), migratedInBefore + assets);
        assertEq(_totalMigratedOut(GENESIS_UID), migratedOutBefore + assets);
    }

    function _totalMigratedIn(uint248 universeId) internal view returns (uint128 migratedIn) {
        (,,,,,,, migratedIn,,,,,) = multiverse.universes(universeId);
    }

    function _totalMigratedOut(uint248 universeId) internal view returns (uint128 migratedOut) {
        (,,,,,,,,,, migratedOut,,) = multiverse.universes(universeId);
    }

    function _favoriteChild(uint248 universeId) internal view returns (uint248 favoriteChild) {
        (,,,,, favoriteChild,,,,,,,) = multiverse.universes(universeId);
    }

    /// @dev The average per whole token the universe's pool pays out, floored like redeem prices it.
    function _poolAverage(uint248 universeId) internal view returns (uint256) {
        return tokenizer.pooledRep(universeId) / (tokenizer.token(universeId).totalSupply() / tokenizer.ONE_QUERY());
    }

    /// @dev The QueryToken of the genesis universe, typed as the concrete contract.
    function _genesisQueryToken() internal view returns (QueryToken) {
        return QueryToken(address(tokenizer.token(GENESIS_UID)));
    }
}
