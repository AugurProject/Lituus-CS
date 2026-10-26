// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { QueryTokenizerFixtures } from "../unit/QueryTokenizer.fixtures.sol";

/// @notice Fuzzed pool-accounting properties of the QueryTokenizer: deposits and redemptions
///         reconcile exactly, the redeem price is the floored pool average and never decreases
///         between mints, the pool never pays out more wREP than it holds, and the mint price
///         always respects the premium formula and the fork-threshold cap.
contract QueryTokenizerFuzzTest is QueryTokenizerFixtures {
    /*//////////////////////////////////////////////////////////////
                               MINT PRICE
    //////////////////////////////////////////////////////////////*/
    function testFuzz_MintPrice_RespectsFormulaAndCap(uint256 fee) public {
        fee = bound(fee, 0, 1e27);
        feeCtl.setFee(fee);

        // Clean state: the demand modifier is exactly 1.0, so the uncapped preview is the raw fee.
        uint256 preview = _previewUncappedFee();
        assertEq(preview, fee);

        // `expected` never exceeds the cap by construction
        uint256 cap = _queryFeeCapWrep();
        uint256 uncappedPrice = preview * 11 / 10;
        uint256 expected = uncappedPrice > cap ? cap : uncappedPrice;

        assertEq(tokenizer.mintPrice(GENESIS_UID), expected);
    }

    /*//////////////////////////////////////////////////////////////
                          MINT/REDEEM ACCOUNTING
    //////////////////////////////////////////////////////////////*/
    function testFuzz_MintRedeem_PoolAccounting(
        uint8 mintCount1,
        uint8 mintCount2,
        uint8 mintCount3,
        uint256 fee1,
        uint256 fee2,
        uint256 fee3,
        uint8 redeemCount1,
        uint8 redeemCount2
    ) public {
        // Mint batches at independent fees interleaved with redemption runs. The fee bounds
        // deliberately cross the fork-threshold cap (75 REP) — costs are read live from mintPrice,
        // so capped and uncapped deposits must reconcile identically; the worst case
        // (9 tokens * 75 REP) stays within the funded balance. The FIRST batch is forced (a
        // redemption needs at least one token); the later batches are OPTIONAL — zero keeps
        // single-batch pools in the fuzzed distribution (mint(0) reverts with ZeroAmount, hence
        // the guards).
        uint256 m1 = bound(mintCount1, 1, 3);
        uint256 m2 = bound(mintCount2, 0, 3);
        uint256 m3 = bound(mintCount3, 0, 3);
        fee1 = bound(fee1, 0.01 ether, 200 ether);
        fee2 = bound(fee2, 0.01 ether, 200 ether);
        fee3 = bound(fee3, 0.01 ether, 200 ether);

        feeCtl.setFee(fee1);
        uint256 deposited = _mintTokens(user, m1);
        if (m2 > 0) {
            feeCtl.setFee(fee2);
            deposited += _mintTokens(user, m2);
        }

        uint256 firstRun = bound(redeemCount1, 1, m1 + m2);
        uint256 paid = _redeemRun(firstRun);

        // Interleave: a mint AFTER redemptions, with floor dust possibly in the pool — the
        // average recomputes over dust + fresh deposits
        if (m3 > 0) {
            feeCtl.setFee(fee3);
            deposited += _mintTokens(user, m3);
        }

        uint256 remaining = m1 + m2 + m3 - firstRun;
        uint256 secondRun = remaining == 0 ? 0 : bound(redeemCount2, 0, remaining);
        paid += _redeemRun(secondRun);

        // Deposits and payouts reconcile exactly; floor dust stays pooled.
        assertEq(tokenizer.pooledRep(GENESIS_UID), deposited - paid);
        assertEq(_genesisQueryToken().totalSupply(), (remaining - secondRun) * tokenizer.ONE_QUERY());

        // Solvency: the tokenizer's whole wREP balance IS the pool — it can always pay what it owes.
        assertEq(genesisRep.balanceOf(address(tokenizer)), tokenizer.pooledRep(GENESIS_UID));
    }

    /// @dev Redeems `count` tokens as `user` and returns the total wREP paid out. Within a run
    ///      uninterrupted by mints, the floored pool average can never decrease (each redemption
    ///      removes exactly the floor, concentrating the remainder) — asserted per step.
    ///      _redeemToken itself asserts each price is exactly floor(pool / wholeSupply) and that
    ///      the pool, token supply, and wREP balances move by exactly that price.
    function _redeemRun(uint256 count) internal returns (uint256 totalPaid) {
        uint256 previousPrice;
        for (uint256 i = 0; i < count; i++) {
            (uint256 price,) = _redeemToken(user);
            assertGe(price, previousPrice);
            previousPrice = price;
            totalPaid += price;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        REDEEMED FEE ENTERS ORACLE
    //////////////////////////////////////////////////////////////*/
    function testFuzz_Redeem_RecordedFeeAlwaysBacked(uint256 fee, uint8 mintCount) public {
        // Whatever the mint fee, the redeemed query's recorded fee equals the wREP actually pushed
        // to the Multiverse (asserted inside _redeemToken), so tokenizer queries are always backed.
        fee = bound(fee, 1, 50 ether);
        uint256 mints = bound(mintCount, 1, 5);

        feeCtl.setFee(fee);
        _mintTokens(user, mints);

        (uint256 price, uint256 queryId) = _redeemToken(user);
        (,, uint256 recordedFee,,) = multiverse.queries(queryId);
        assertEq(recordedFee, price);
    }

    /*//////////////////////////////////////////////////////////////
                            FORK MIGRATION
    //////////////////////////////////////////////////////////////*/
    /// @dev Tokens minted at two fees (crossing the cap), the parent's rate possibly moved by a burn, then a
    ///      fork with some tokens migrated into each child, a mint in one child at its own price and a
    ///      redemption there. Across the fork: the parent pool gives up exactly the average per token and its
    ///      average never moves; what the children hold, in underlying, is what the parent gave up less the child
    ///      vault's rounding (under 2 wei per migration: once into shares, once back); a child's average is the
    ///      blend of what arrived and what was minted there; and every pool is exactly the tokenizer's wREP
    ///      balance in that universe.
    function testFuzz_Migrate_PoolsReconcileAcrossTheFork(
        uint8 mintCount1,
        uint8 mintCount2,
        uint256 fee1,
        uint256 fee2,
        uint8 toA,
        uint8 toB,
        uint256 burnSeed,
        uint8 childMints
    ) public {
        uint256 m1 = bound(mintCount1, 1, 3);
        uint256 m2 = bound(mintCount2, 0, 3);
        fee1 = bound(fee1, 0.01 ether, 60 ether);
        fee2 = bound(fee2, 0.01 ether, 60 ether);
        feeCtl.setFee(fee1);
        uint256 deposited = _mintTokens(user, m1);
        if (m2 > 0) {
            feeCtl.setFee(fee2);
            deposited += _mintTokens(user, m2);
        }
        uint256 minted = m1 + m2;
        feeCtl.setFee(DEFAULT_FEE);

        // A burn before the fork moves the parent's rate (the children open at it); zero keeps it at 1.
        uint256 sharesToBurn = bound(burnSeed, 0, 100 ether);
        if (sharesToBurn > 0) {
            vm.prank(user);
            genesisRep.transfer(address(multiverse), sharesToBurn);
            vm.prank(address(multiverse));
            genesisRep.burnShares(sharesToBurn);
        }

        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_B);
        uint248 childA = _childId(GENESIS_UID, OUTCOME_A);
        uint248 childB = _childId(GENESIS_UID, OUTCOME_B);

        uint256 a = bound(toA, 0, minted);
        uint256 b = bound(toB, 0, minted - a);
        uint256 averageBefore = _poolAverage(GENESIS_UID);
        uint256 migrated;
        uint256 givenUp;
        uint256 received;
        uint256 migrations;
        if (a > 0) {
            (uint256 migratedRep, uint256 childShares) = _migrateTokens(user, OUTCOME_A, a);
            assertEq(migratedRep, averageBefore * a);
            migrated += migratedRep;
            givenUp += genesisRep.convertToAssets(migratedRep);
            received += multiverse.repTokenOf(childA).convertToAssets(childShares);
            migrations++;
        }
        if (b > 0) {
            // _migrateTokens asserts the share against the average read right before it.
            (uint256 migratedRep, uint256 childShares) = _migrateTokens(user, OUTCOME_B, b);
            migrated += migratedRep;
            givenUp += genesisRep.convertToAssets(migratedRep);
            received += multiverse.repTokenOf(childB).convertToAssets(childShares);
            migrations++;
        }
        assertEq(tokenizer.pooledRep(GENESIS_UID), deposited - migrated);
        // Like a redemption run, a migration concentrates the floor dust on the tokens that stay: the floored
        // average cannot drop, and the dust is under one wei per token minted.
        if (minted - a - b > 0) {
            assertGe(_poolAverage(GENESIS_UID), averageBefore);
            assertLt(_poolAverage(GENESIS_UID), averageBefore + minted);
        }
        assertLe(received, givenUp);
        assertApproxEqAbs(received, givenUp, 2 * migrations);

        // A mint in child A at the child's own price blends into what arrived there.
        uint256 childMintCount = bound(childMints, 0, 2);
        uint256 childDeposited;
        if (childMintCount > 0) {
            ILituusRep childRepA = multiverse.repTokenOf(childA);
            vm.prank(bystander);
            multiverse.migrate(GENESIS_UID, OUTCOME_A, 100 ether);
            vm.prank(bystander);
            childRepA.approve(address(tokenizer), type(uint256).max);
            childDeposited = tokenizer.mintPrice(childA) * childMintCount;
            vm.prank(bystander);
            tokenizer.mint(childA, childMintCount);
        }
        uint256 arrivedInA = tokenizer.pooledRep(childA) - childDeposited;
        if (a + childMintCount > 0) {
            assertEq(_poolAverage(childA), (arrivedInA + childDeposited) / (a + childMintCount));
            (uint256 price,) = _redeemTokenIn(childA, a > 0 ? user : bystander);
            assertEq(price, (arrivedInA + childDeposited) / (a + childMintCount));
        }

        // Solvency in every universe: the tokenizer's wREP balance IS the pool.
        assertEq(genesisRep.balanceOf(address(tokenizer)), tokenizer.pooledRep(GENESIS_UID));
        assertEq(multiverse.repTokenOf(childA).balanceOf(address(tokenizer)), tokenizer.pooledRep(childA));
        assertEq(multiverse.repTokenOf(childB).balanceOf(address(tokenizer)), tokenizer.pooledRep(childB));
    }
}
