// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { QueryToken } from "src/QueryToken.sol";
import { QueryTokenizer } from "src/QueryTokenizer.sol";
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
    // The funded actors wrap 3 × 1000 underlying into the genesis vault, so MockZoltar's fork
    // threshold is 3000 / 20 = 150 REP. Half of it — the cap on both the tokenizer's mint price
    // and the direct-path query fee — is the single derivation every cap assertion builds on.
    uint256 internal constant HALF_FORK_THRESHOLD = 75 ether;

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
        return new Multiverse(zoltar, GENESIS_UID, controller, address(tokenizer));
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
        IQueryToken queryToken = tokenizer.token(GENESIS_UID);
        uint256 wholeSupply = queryToken.totalSupply() / tokenizer.ONE_QUERY();
        uint256 pooledBefore = tokenizer.pooledRep(GENESIS_UID);
        price = pooledBefore / wholeSupply;
        queryId = multiverse.queryCount();

        uint256 balanceBefore = queryToken.balanceOf(account);
        uint256 tokenizerRepBefore = genesisRep.balanceOf(address(tokenizer));
        uint256 multiverseRepBefore = genesisRep.balanceOf(address(multiverse));

        // Emission order inside redeem(): the Multiverse emits QueryCreated, then the tokenizer
        // emits Redeemed.
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryCreated(account, queryId, GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        vm.expectEmit(true, true, true, true, address(tokenizer));
        emit QueryTokenizer.Redeemed(account, GENESIS_UID, price);
        vm.prank(account);
        tokenizer.redeem(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        assertEq(queryToken.balanceOf(account), balanceBefore - tokenizer.ONE_QUERY());
        assertEq(tokenizer.pooledRep(GENESIS_UID), pooledBefore - price);
        assertEq(genesisRep.balanceOf(address(tokenizer)), tokenizerRepBefore - price);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseRepBefore + price);

        assertEq(multiverse.queryCount(), queryId + 1);
        (uint8 numberOfOutcomes, uint248 originUniverse, uint256 fee, string memory question) =
            multiverse.queries(queryId);
        assertEq(numberOfOutcomes, DEFAULT_NUMBER_OF_OUTCOMES);
        assertEq(originUniverse, GENESIS_UID);
        assertEq(fee, price);
        assertEq(question, DEFAULT_QUESTION);

        (uint48 queryCreateTime, uint8 outcome,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
        assertEq(queryCreateTime, uint48(vm.getBlockTimestamp()));
        assertEq(outcome, multiverse.UNRESOLVED());
    }

    /// @dev The QueryToken of the genesis universe, typed as the concrete contract.
    function _genesisQueryToken() internal view returns (QueryToken) {
        return QueryToken(address(tokenizer.token(GENESIS_UID)));
    }
}
