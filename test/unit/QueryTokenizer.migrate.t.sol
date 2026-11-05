// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { LituusRep } from "src/LituusRep.sol";
import { Multiverse } from "src/Multiverse.sol";
import { QueryTokenizer } from "src/QueryTokenizer.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { IQueryToken } from "src/interfaces/IQueryToken.sol";
import { QueryTokenizerFixtures } from "./QueryTokenizer.fixtures.sol";

/// @notice Query tokens across a fork: a holder migrates whole tokens into a child, the parent tokens burn,
///         their share of the pool moves through the Multiverse as a counted vote, and the child's tokens
///         back the same number of queries there at the child pool's average.
contract QueryTokenizerMigrateTest is QueryTokenizerFixtures {
    uint256 internal constant MINTED = 3;

    uint248 internal childA;
    uint248 internal childB;

    /// @dev `user` holds three genesis tokens minted at the default fee (1.1 wREP each), then the genesis forks
    ///      and both children spawn. Nothing else has migrated, so the counters start from zero.
    function _mintAndFork() internal returns (uint256 mintCost) {
        mintCost = _mintTokens(user, MINTED);
        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_B);
        childA = _childId(GENESIS_UID, OUTCOME_A);
        childB = _childId(GENESIS_UID, OUTCOME_B);
    }

    /// @dev Gives `account` child wREP of `childId` (its own genesis wREP migrated) and approves the tokenizer
    ///      on it, so it can mint in the child.
    function _fundInChild(address account, uint248 childId, uint256 outcome, uint256 shares) internal {
        ILituusRep childRep = multiverse.repTokenOf(childId);
        vm.prank(account);
        multiverse.migrate(GENESIS_UID, outcome, shares);
        vm.prank(account);
        childRep.approve(address(tokenizer), type(uint256).max);
    }

    /// @dev Forks child A on a query of its own (`user` migrates genesis wREP into it to pay and escalate) and
    ///      spawns its child for OUTCOME_A, all at the current timestamp.
    function _forkChildA() internal returns (uint248 grandchild) {
        ILituusRep childRep = multiverse.repTokenOf(childA);
        vm.prank(user);
        multiverse.migrate(GENESIS_UID, OUTCOME_A, 200 ether);
        vm.prank(user);
        childRep.approve(address(multiverse), type(uint256).max);
        uint256 queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(childA, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        _escalateToFork(childA, queryId, user, user);
        multiverse.spawnChildUniverse(childA, OUTCOME_A);
        grandchild = _childId(childA, OUTCOME_A);
    }

    /* ============================================== HAPPY PATHS =============================================== */

    function test_Migrate_HappyPath() public {
        uint256 mintCost = _mintAndFork();

        (uint256 migratedRep, uint256 childShares) = _migrateTokens(user, OUTCOME_A, 2);

        // Two of three tokens leave with two thirds of the pool; at rate 1 the child gets the same amount.
        assertEq(migratedRep, mintCost * 2 / 3);
        assertEq(childShares, migratedRep);
        assertEq(tokenizer.pooledRep(GENESIS_UID), mintCost / 3);
        assertEq(tokenizer.pooledRep(childA), migratedRep);
        assertEq(_favoriteChild(GENESIS_UID), childA);
    }

    function test_Migrate_DeploysChildTokenOnFirstArrival() public {
        _mintAndFork();
        address predictedToken = vm.computeCreateAddress(address(tokenizer), vm.getNonce(address(tokenizer)));
        uint256 migratedRep = tokenizer.pooledRep(GENESIS_UID) / MINTED;

        // Emission order: the Multiverse's wallet migration, then the child token's deployment, then the
        // tokenizer's migration (rate 1: shares and assets equal).
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.Migrated(address(tokenizer), GENESIS_UID, childA, migratedRep);
        vm.expectEmit(true, true, true, true, address(tokenizer));
        emit QueryTokenizer.QueryTokenDeployed(childA, predictedToken);
        vm.expectEmit(true, true, true, true, address(tokenizer));
        emit QueryTokenizer.QueryTokensMigrated(user, GENESIS_UID, childA, 1, migratedRep);
        vm.prank(user);
        tokenizer.migrate(GENESIS_UID, OUTCOME_A, 1);

        IQueryToken childToken = tokenizer.token(childA);
        assertEq(address(childToken), predictedToken);
        // The state _migrateTokens would assert: the parent token burned and its pool share gone, the child
        // token minted and the share pooled there (rate 1: the same amount), the vote counted.
        uint256 oneQuery = tokenizer.ONE_QUERY();
        assertEq(tokenizer.token(GENESIS_UID).balanceOf(user), (MINTED - 1) * oneQuery);
        assertEq(tokenizer.token(GENESIS_UID).totalSupply(), (MINTED - 1) * oneQuery);
        assertEq(tokenizer.pooledRep(GENESIS_UID), (MINTED - 1) * migratedRep);
        assertEq(genesisRep.balanceOf(address(tokenizer)), (MINTED - 1) * migratedRep);
        assertEq(childToken.balanceOf(user), oneQuery);
        assertEq(childToken.totalSupply(), oneQuery);
        assertEq(tokenizer.pooledRep(childA), migratedRep);
        assertEq(multiverse.repTokenOf(childA).balanceOf(address(tokenizer)), migratedRep);
        assertEq(_totalMigratedIn(childA), migratedRep);
        assertEq(_totalMigratedOut(GENESIS_UID), migratedRep);

        // A second arrival reuses it.
        _migrateTokens(user, OUTCOME_A, 1);
        assertEq(address(tokenizer.token(childA)), predictedToken);
        assertEq(tokenizer.token(childA).totalSupply(), 2 * tokenizer.ONE_QUERY());
    }

    function test_Migrate_ParentAverageUnchanged() public {
        // Tokens minted at two fees: the pool average is not a mint price, and it has floor dust.
        _mintTokens(user, 1);
        feeCtl.setFee(2 ether);
        _mintTokens(user, 2);
        assertEq(tokenizer.pooledRep(GENESIS_UID), 5.5 ether);
        feeCtl.setFee(DEFAULT_FEE);
        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);

        uint256 averageBefore = _poolAverage(GENESIS_UID);
        (uint256 migratedRep,) = _migrateTokens(user, OUTCOME_A, 1);

        // The token leaves with exactly the average; the 1 wei of dust stays over two tokens and floors away, so
        // the holders who stay see the same average.
        assertEq(migratedRep, averageBefore);
        assertEq(_poolAverage(GENESIS_UID), averageBefore);
    }

    function test_Migrate_LastTokensOutTakeTheWholePool() public {
        _mintTokens(user, 1);
        feeCtl.setFee(2 ether);
        _mintTokens(user, 2);
        feeCtl.setFee(DEFAULT_FEE);
        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);

        // 5.5 / 3 floors, so the first token leaves a fraction of a wei behind for the two that stay...
        uint256 pool = 5.5 ether;
        (uint256 first,) = _migrateTokens(user, OUTCOME_A, 1);
        assertEq(first, pool / 3);
        assertEq(tokenizer.pooledRep(GENESIS_UID), pool - first);

        // ...and the last two take everything that is left: nothing stays in a pool nobody can sweep.
        (uint256 rest,) = _migrateTokens(user, OUTCOME_A, 2);
        assertEq(rest, pool - first);
        assertEq(tokenizer.pooledRep(GENESIS_UID), 0);
        assertEq(tokenizer.token(GENESIS_UID).totalSupply(), 0);
    }

    function test_Migrate_AllTokensInOneBatchTakeTheWholePool() public {
        _mintTokens(user, 1);
        feeCtl.setFee(2 ether);
        _mintTokens(user, 2);
        feeCtl.setFee(DEFAULT_FEE);
        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);

        // 5.5 / 3 does not divide evenly, yet one batch of all three takes all the pool: 5.5 × 3 / 3.
        // (Pricing the batch at the floored average, 3 × floor(5.5 / 3), would strand 1 wei.)
        (uint256 migratedRep, uint256 childShares) = _migrateTokens(user, OUTCOME_A, 3);
        assertEq(migratedRep, 5.5 ether);
        assertEq(tokenizer.pooledRep(GENESIS_UID), 0);
        assertEq(genesisRep.balanceOf(address(tokenizer)), 0);
        assertEq(tokenizer.token(GENESIS_UID).totalSupply(), 0);
        assertEq(tokenizer.pooledRep(_childId(GENESIS_UID, OUTCOME_A)), childShares);
    }

    function test_Migrate_SplitAcrossChildren() public {
        uint256 mintCost = _mintAndFork();

        (uint256 toA,) = _migrateTokens(user, OUTCOME_A, 1);
        (uint256 toB,) = _migrateTokens(user, OUTCOME_B, 2);

        assertEq(toA, mintCost / 3);
        assertEq(toB, mintCost * 2 / 3);
        assertEq(tokenizer.pooledRep(GENESIS_UID), 0);
        assertEq(tokenizer.token(GENESIS_UID).totalSupply(), 0);
        assertEq(tokenizer.token(childA).balanceOf(user), tokenizer.ONE_QUERY());
        assertEq(tokenizer.token(childB).balanceOf(user), 2 * tokenizer.ONE_QUERY());
        // Each child's tokens are backed by that child's pool only.
        assertEq(tokenizer.pooledRep(childA), toA);
        assertEq(tokenizer.pooledRep(childB), toB);
        assertEq(_favoriteChild(GENESIS_UID), childB);
    }

    function test_Migrate_CountsAsVote() public {
        _mintAndFork();
        vm.prank(challenger);
        multiverse.migrate(GENESIS_UID, OUTCOME_B, 3 ether);
        assertEq(_favoriteChild(GENESIS_UID), childB);

        // 3.3 wREP of pool arrive in A, more than the 3 wREP in B: the tokens' pool votes like wallet wREP.
        _migrateTokens(user, OUTCOME_A, 3);

        assertEq(_favoriteChild(GENESIS_UID), childA);
        assertEq(_totalMigratedIn(childA), 3.3 ether);
        assertEq(_totalMigratedOut(GENESIS_UID), 6.3 ether);
    }

    function test_Migrate_RedeemInChildPaysChildAverage() public {
        _mintAndFork();
        _migrateTokens(user, OUTCOME_A, 2);

        // The child's pool holds what the two tokens brought, so each redeems at the parent's old average.
        (uint256 price, uint256 queryId) = _redeemTokenIn(childA, user);
        assertEq(price, 1.1 ether);
        assertEq(tokenizer.pooledRep(childA), 1.1 ether);
        (, uint248 originUniverse,,,) = multiverse.queries(queryId);
        assertEq(originUniverse, childA);
    }

    function test_Migrate_ChildAverageBlendsWithChildMints() public {
        _mintAndFork();
        _migrateTokens(user, OUTCOME_A, 2);
        _fundInChild(bystander, childA, OUTCOME_A, 100 ether);

        // A mint in the child at the child's own price joins the pool like any mint; the average blends.
        uint256 childPrice = tokenizer.mintPrice(childA);
        vm.prank(bystander);
        tokenizer.mint(childA, 1);
        assertEq(tokenizer.pooledRep(childA), 2.2 ether + childPrice);

        (uint256 price,) = _redeemTokenIn(childA, user);
        assertEq(price, (2.2 ether + childPrice) / 3);
    }

    function test_Migrate_AtParentRateAboveOne() public {
        // A burn in the genesis vault before the fork moves its rate; the child vault opens at that rate, so
        // the pool share converts through assets and the child pool holds what the parent pool gave up.
        uint256 mintCost = _mintTokens(user, MINTED);
        vm.prank(user);
        genesisRep.transfer(address(multiverse), 50 ether);
        vm.prank(address(multiverse));
        genesisRep.burnShares(50 ether);
        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        childA = _childId(GENESIS_UID, OUTCOME_A);
        ILituusRep childRep = multiverse.repTokenOf(childA);

        (uint256 migratedRep, uint256 childShares) = _migrateTokens(user, OUTCOME_A, 2);

        assertEq(migratedRep, mintCost * 2 / 3);
        assertLe(childShares, migratedRep);
        // The child wraps at its rate rounding down, so at most 1 wei of underlying stays with the child vault.
        uint256 childAssets = childRep.convertToAssets(childShares);
        uint256 parentAssets = genesisRep.convertToAssets(migratedRep);
        assertLe(childAssets, parentAssets);
        assertApproxEqAbs(childAssets, parentAssets, 1);
        assertEq(childRep.balanceOf(address(tokenizer)), tokenizer.pooledRep(childA));
    }

    function test_Migrate_IsTheOnlyPathOutOfAForkedUniverse() public {
        _mintAndFork();

        // Minting and redeeming are frozen in the parent from the fork on.
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        tokenizer.mint(GENESIS_UID, 1);
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        tokenizer.redeem(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        // Inside the window the tokens can still leave; after it they are stuck with their share of the pool.
        _migrateTokens(user, OUTCOME_A, 1);
        vm.warp(vm.getBlockTimestamp() + MIGRATION_DURATION);
        vm.prank(user);
        vm.expectRevert(Multiverse.MigrationWindowClosed.selector);
        tokenizer.migrate(GENESIS_UID, OUTCOME_A, 1);
        assertEq(tokenizer.token(GENESIS_UID).balanceOf(user), 2 * tokenizer.ONE_QUERY());
        assertEq(tokenizer.pooledRep(GENESIS_UID), 2.2 ether);
        assertEq(genesisRep.balanceOf(address(tokenizer)), 2.2 ether);
    }

    function test_Migrate_IntoChildTokenDeployedByAMint() public {
        // A mint in child A deploys its token before anything arrives; the arrival reuses it and blends in.
        _mintAndFork();
        _fundInChild(bystander, childA, OUTCOME_A, 100 ether);
        uint256 childPrice = tokenizer.mintPrice(childA);
        vm.prank(bystander);
        tokenizer.mint(childA, 1);
        IQueryToken childToken = tokenizer.token(childA);

        (uint256 migratedRep,) = _migrateTokens(user, OUTCOME_A, 2);

        assertEq(address(tokenizer.token(childA)), address(childToken));
        assertEq(childToken.totalSupply(), 3 * tokenizer.ONE_QUERY());
        assertEq(tokenizer.pooledRep(childA), childPrice + migratedRep);
        (uint256 price,) = _redeemTokenIn(childA, user);
        assertEq(price, (childPrice + migratedRep) / 3);
    }

    function test_Migrate_ThroughNestedForks() public {
        _mintAndFork();
        _migrateTokens(user, OUTCOME_A, 1);
        uint248 grandchild = _forkChildA();

        // Child A forked: its tokens are frozen there like the genesis ones.
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        tokenizer.redeem(childA, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        // A genesis token still arrives in the already-forked child A...
        _migrateTokens(user, OUTCOME_A, 1);
        assertEq(tokenizer.token(childA).totalSupply(), 2 * tokenizer.ONE_QUERY());

        // ...and both move on into the grandchild, where they redeem at the grandchild's average.
        (uint256 migratedRep, uint256 grandchildShares) = _migrateTokensIn(childA, user, OUTCOME_A, 2);
        assertEq(migratedRep, 2.2 ether);
        assertEq(tokenizer.pooledRep(childA), 0);
        assertEq(tokenizer.pooledRep(grandchild), grandchildShares);
        (uint256 price,) = _redeemTokenIn(grandchild, user);
        assertEq(price, grandchildShares / 2);
    }

    function test_Migrate_NestedWindowStaysOpenUntilParentResolves() public {
        _mintAndFork();
        _migrateTokens(user, OUTCOME_A, 2);
        _forkChildA();

        // Both windows are past their clock: the genesis one is closed, child A's stays open while the
        // genesis fork is unresolved.
        vm.warp(vm.getBlockTimestamp() + MIGRATION_DURATION);
        vm.prank(user);
        vm.expectRevert(Multiverse.MigrationWindowClosed.selector);
        tokenizer.migrate(GENESIS_UID, OUTCOME_A, 1);
        _migrateTokensIn(childA, user, OUTCOME_A, 1);

        // Once the genesis fork resolves, child A's window closes too.
        multiverse.advanceForkState(GENESIS_UID);
        vm.prank(user);
        vm.expectRevert(Multiverse.MigrationWindowClosed.selector);
        tokenizer.migrate(childA, OUTCOME_A, 1);
    }

    /* ================================================ REVERTS ================================================= */

    function test_RevertWhen_Migrate_ForkResolved() public {
        _mintAndFork();
        vm.warp(vm.getBlockTimestamp() + MIGRATION_DURATION);
        multiverse.advanceForkState(GENESIS_UID);

        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        tokenizer.migrate(GENESIS_UID, OUTCOME_A, 1);
        assertEq(tokenizer.token(GENESIS_UID).balanceOf(user), MINTED * tokenizer.ONE_QUERY());
        assertEq(tokenizer.pooledRep(GENESIS_UID), 3.3 ether);
    }

    function test_RevertWhen_Migrate_ShareRoundsToZeroChildShares() public {
        // Pins a known edge: a 1 wei pool share, at a parent rate above 1, is worth less than one child share,
        // so the child vault's wrap rejects it and the token cannot leave the forked universe.
        feeCtl.setFee(1);
        _mintTokens(user, 1);
        assertEq(tokenizer.pooledRep(GENESIS_UID), 1);
        feeCtl.setFee(DEFAULT_FEE);
        vm.prank(user);
        genesisRep.transfer(address(multiverse), 50 ether);
        vm.prank(address(multiverse));
        genesisRep.burnShares(50 ether);
        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);

        vm.prank(user);
        vm.expectRevert(LituusRep.ZeroShares.selector);
        tokenizer.migrate(GENESIS_UID, OUTCOME_A, 1);
        assertEq(tokenizer.token(GENESIS_UID).balanceOf(user), tokenizer.ONE_QUERY());
        assertEq(tokenizer.pooledRep(GENESIS_UID), 1);
    }

    function test_RevertWhen_Migrate_ZeroAmount() public {
        _mintAndFork();
        vm.prank(user);
        vm.expectRevert(QueryTokenizer.ZeroAmount.selector);
        tokenizer.migrate(GENESIS_UID, OUTCOME_A, 0);
    }

    function test_RevertWhen_Migrate_TokenNotExisting() public {
        // Nothing was ever minted in the genesis, so there is no token to migrate.
        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        vm.prank(user);
        vm.expectRevert(QueryTokenizer.QueryTokenNotExisting.selector);
        tokenizer.migrate(GENESIS_UID, OUTCOME_A, 1);
    }

    function test_RevertWhen_Migrate_NoWholeTokens() public {
        // Every token has already left: the supply is zero, checked before any balance.
        _mintAndFork();
        _migrateTokens(user, OUTCOME_A, MINTED);
        vm.prank(user);
        vm.expectRevert(QueryTokenizer.NoWholeTokens.selector);
        tokenizer.migrate(GENESIS_UID, OUTCOME_A, 1);
    }

    function test_RevertWhen_Migrate_CallerHoldsLess() public {
        _mintAndFork();
        IQueryToken parentToken = tokenizer.token(GENESIS_UID);
        uint256 oneQuery = tokenizer.ONE_QUERY();

        // The supply has the tokens, the caller does not: the burn fails on the caller's balance.
        vm.prank(user);
        assertTrue(parentToken.transfer(bystander, oneQuery));
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 2 * oneQuery, 3 * oneQuery)
        );
        tokenizer.migrate(GENESIS_UID, OUTCOME_A, 3);

        // The transferred token migrates for whoever holds it.
        _migrateTokens(bystander, OUTCOME_A, 1);
    }

    function test_RevertWhen_Migrate_UniverseNotForked() public {
        _mintTokens(user, 1);
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        tokenizer.migrate(GENESIS_UID, OUTCOME_A, 1);
    }

    function test_RevertWhen_Migrate_ChildNotSpawned() public {
        _mintTokens(user, 1);
        _forkGenesis();
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        tokenizer.migrate(GENESIS_UID, OUTCOME_A, 1);
    }

    function test_RevertWhen_Migrate_WindowClosed() public {
        _mintAndFork();
        vm.warp(vm.getBlockTimestamp() + MIGRATION_DURATION);
        vm.prank(user);
        vm.expectRevert(Multiverse.MigrationWindowClosed.selector);
        tokenizer.migrate(GENESIS_UID, OUTCOME_A, 1);
    }
}
