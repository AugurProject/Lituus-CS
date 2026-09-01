// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import { Multiverse } from "src/Multiverse.sol";
import { QueryToken } from "src/QueryToken.sol";
import { QueryTokenizer } from "src/QueryTokenizer.sol";
import { IMultiverse } from "src/interfaces/IMultiverse.sol";
import { QueryTokenizerFixtures } from "./QueryTokenizer.fixtures.sol";

contract QueryTokenizerTest is QueryTokenizerFixtures {
    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR / SET MULTIVERSE
    //////////////////////////////////////////////////////////////*/
    function test_Constructor_Wiring() public view {
        assertEq(address(tokenizer.multiverse()), address(multiverse));
        assertEq(tokenizer.ONE_QUERY(), 1e18);
        assertEq(tokenizer.PREMIUM_NUMERATOR(), 11);
        assertEq(tokenizer.PREMIUM_DENOMINATOR(), 10);
    }

    function test_RevertWhen_SetMultiverse_NotDeployer() public {
        QueryTokenizer fresh = new QueryTokenizer();

        vm.prank(user);
        vm.expectRevert(QueryTokenizer.CannotSet.selector);
        fresh.setMultiverse(IMultiverse(address(multiverse)));
    }

    function test_RevertWhen_SetMultiverse_AlreadySet() public {
        // The fixture already wired `tokenizer` (deployer = this test contract), so a second set —
        // even by the deployer — must fail.
        vm.expectRevert(QueryTokenizer.CannotSet.selector);
        tokenizer.setMultiverse(IMultiverse(address(multiverse)));
    }

    function test_SetMultiverse_SetsOnce() public {
        QueryTokenizer fresh = new QueryTokenizer();
        assertEq(address(fresh.multiverse()), address(0));

        fresh.setMultiverse(IMultiverse(address(multiverse)));

        assertEq(address(fresh.multiverse()), address(multiverse));
    }

    /*//////////////////////////////////////////////////////////////
                               MINT PRICE
    //////////////////////////////////////////////////////////////*/
    function test_MintPrice_IsPreviewFeePlusPremium() public view {
        // Clean state at START_TIME: the demand modifier is exactly 1.0, so the preview equals the
        // controller fee and the mint price is exactly fee × 11/10.
        uint256 preview = _previewUncappedFee();
        assertEq(preview, DEFAULT_FEE);
        assertEq(tokenizer.mintPrice(GENESIS_UID), DEFAULT_FEE * 11 / 10);
    }

    function test_MintPrice_TracksPreviewAfterVolume() public {
        // Volume moves the preview; the price must keep tracking preview × 11/10.
        _createDefaultQuery();
        _createDefaultQuery();

        uint256 preview = _previewUncappedFee();
        assertGt(preview, DEFAULT_FEE);
        assertEq(tokenizer.mintPrice(GENESIS_UID), preview * 11 / 10);
    }

    function test_MintPrice_CapBindsAtHalfForkThreshold() public {
        // Pin the fixture constant to the live derivation once, here.
        assertEq(_queryFeeCapWrep(), HALF_FORK_THRESHOLD);

        // fee 100 → preview 100 → premium price 110 > 75 → capped.
        feeCtl.setFee(100 ether);
        assertEq(tokenizer.mintPrice(GENESIS_UID), HALF_FORK_THRESHOLD);

        // Minting at the capped price deposits exactly the cap per token.
        uint256 cost = _mintTokens(user, 1);
        assertEq(cost, HALF_FORK_THRESHOLD);
        assertEq(tokenizer.pooledRep(GENESIS_UID), HALF_FORK_THRESHOLD);
    }

    function test_RevertWhen_MintPrice_UniverseNotExisting() public {
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        tokenizer.mintPrice(GENESIS_UID + 1);
    }

    /*//////////////////////////////////////////////////////////////
                                  MINT
    //////////////////////////////////////////////////////////////*/
    function test_RevertWhen_Mint_ZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(QueryTokenizer.ZeroAmount.selector);
        tokenizer.mint(GENESIS_UID, 0);
    }

    function test_RevertWhen_Mint_ZeroCost() public {
        // A zero controller fee makes the mint price zero; free tokens would dilute the pool.
        feeCtl.setFee(0);

        vm.prank(user);
        vm.expectRevert(QueryTokenizer.ZeroCost.selector);
        tokenizer.mint(GENESIS_UID, 1);
    }

    function test_RevertWhen_Mint_UniverseNotExisting() public {
        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        tokenizer.mint(GENESIS_UID + 1, 1);
    }

    function test_Mint_HappyPath() public {
        // First mint into the universe also deploys its QueryToken; the address is precomputed
        // from the tokenizer's CREATE nonce so the event can be checked in full.
        address predictedToken = vm.computeCreateAddress(address(tokenizer), vm.getNonce(address(tokenizer)));
        vm.expectEmit(true, true, true, true, address(tokenizer));
        emit QueryTokenizer.QueryTokenDeployed(GENESIS_UID, predictedToken);
        uint256 cost = _mintTokens(user, 2);

        assertEq(address(tokenizer.token(GENESIS_UID)), predictedToken);
        // Price at clean state is exactly DEFAULT_FEE * 11/10 per whole token.
        assertEq(cost, 2 * DEFAULT_FEE * 11 / 10);
        assertEq(tokenizer.pooledRep(GENESIS_UID), cost);
    }

    function test_Mint_SecondMintUsesDeployedToken() public {
        _mintTokens(user, 1);
        QueryToken queryToken = _genesisQueryToken();
        uint256 oneQuery = tokenizer.ONE_QUERY();
        assertEq(queryToken.totalSupply(), oneQuery);

        _mintTokens(bystander, 3);

        assertEq(address(tokenizer.token(GENESIS_UID)), address(queryToken));
        assertEq(queryToken.totalSupply(), 4 * oneQuery);
    }

    function test_Mint_AverageMovesWithNewFees() public {
        // Two mints at different prices: the pool average is the cost-weighted mean.
        uint256 cost1 = _mintTokens(user, 1); // 1.1 REP
        feeCtl.setFee(2 ether);
        uint256 cost2 = _mintTokens(user, 1); // 2.2 REP

        assertEq(cost1, 1.1 ether);
        assertEq(cost2, 2.2 ether);
        assertEq(tokenizer.pooledRep(GENESIS_UID), 3.3 ether);

        // The next redemption pays the average of the two deposits.
        (uint256 price,) = _redeemToken(user);
        assertEq(price, 1.65 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                 REDEEM
    //////////////////////////////////////////////////////////////*/
    function test_RevertWhen_Redeem_TokenNotExisting() public {
        // No mint ever happened in the universe, so no QueryToken exists.
        vm.prank(user);
        vm.expectRevert(QueryTokenizer.QueryTokenNotExisting.selector);
        tokenizer.redeem(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
    }

    function test_RevertWhen_Redeem_NoWholeTokens() public {
        // Mint one, redeem it: the token exists but its supply is back to zero. This is the only
        // reachable NoWholeTokens state — supply only ever moves in whole-token multiples, so a
        // fractional-supply variant cannot exist.
        _mintTokens(user, 1);
        _redeemToken(user);

        vm.prank(user);
        vm.expectRevert(QueryTokenizer.NoWholeTokens.selector);
        tokenizer.redeem(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
    }

    function test_RedeemAfterTransferringTheToken() public {
        _mintTokens(user, 1);
        QueryToken queryToken = _genesisQueryToken();
        uint256 oneQuery = tokenizer.ONE_QUERY();

        // The minter gives the whole token away; supply still has one whole token, so the burn is
        // attempted and reverts on the minter's emptied balance.
        vm.prank(user);
        assertTrue(queryToken.transfer(bystander, oneQuery));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 0, oneQuery));
        tokenizer.redeem(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        // The new holder redeems the transferred query token and is  the query's
        // creator (asserted inside _redeemToken): the redeem follows the ERC20, not the minter.
        (uint256 price,) = _redeemToken(bystander);
        assertEq(price, 1.1 ether);
    }

    function test_RevertWhen_Redeem_CallerHoldsPartToken() public {
        _mintTokens(user, 1);
        QueryToken queryToken = _genesisQueryToken();
        uint256 oneQuery = tokenizer.ONE_QUERY();

        // The holder transfers half of the whole token away; supply still holds one whole token,
        // so the guard passes and the burn reverts on the caller's fractional balance.
        vm.prank(user);
        assertTrue(queryToken.transfer(bystander, oneQuery / 2));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, oneQuery / 2, oneQuery)
        );
        tokenizer.redeem(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
    }

    function test_Redeem_HappyPath_QueryRunsFullOracleLifecycle() public {
        _mintTokens(user, 2);

        // _redeemToken asserts the full redemption effect set: price = pool average, burn of
        // exactly one whole token, pool decrement, wREP push to the Multiverse, the query record
        // (fee = price, creator = redeemer), and both events.
        (uint256 fee, uint256 queryId) = _redeemToken(user);

        assertEq(fee, 1.1 ether);
        assertEq(queryId, 0);
        // The other whole token remains backed by exactly the average.
        assertEq(tokenizer.pooledRep(GENESIS_UID), 1.1 ether);

        // The opening bond is the RECORDED pool-average fee (1.1 REP, below the cap so no clamp is
        // involved) — not the live controller fee (1 REP).
        (uint256 requiredStake,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
        assertEq(requiredStake, fee);

        // From here the query lives an ordinary oracle life. Escalate A → B → A; the first report
        // lands 18 hours in, so the reporter-reward ramp is exactly a quarter of the fee.
        vm.warp(vm.getBlockTimestamp() + 18 hours);
        _report(user, queryId, OUTCOME_A); // 1.1
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        _report(challenger, queryId, OUTCOME_B); // 2.2
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        _report(bystander, queryId, OUTCOME_A); // 4.4
        _warpPastAppealWindow(queryId);

        // Resolution pays the first correct reporter from the POOL-AVERAGE fee: 1.1 / 4 = 0.275.
        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.ReporterRewardPaid(user, GENESIS_UID, queryId, 0.275 ether);
        assertEq(_resolve(user, queryId), OUTCOME_A);

        // Claims: stake plus the pro-rata share of the losing 2.2 after the 20% burn
        // (distributable 1.76 over 5.5 winner-staked).
        assertEq(_claim(user, queryId, 0), 1.452 ether);
        assertEq(_claim(bystander, queryId, 2), 5.808 ether);
    }

    function test_Redeem_AverageInvariance() public {
        // Deposits at three prices; redeeming at the average never moves the remaining average.
        _mintTokens(user, 1); // 1.1
        feeCtl.setFee(2 ether);
        _mintTokens(user, 1); // 2.2
        feeCtl.setFee(3 ether);
        _mintTokens(user, 1); // 3.3
        assertEq(tokenizer.pooledRep(GENESIS_UID), 6.6 ether);

        (uint256 price1,) = _redeemToken(user);
        assertEq(price1, 2.2 ether);
        (uint256 price2,) = _redeemToken(user);
        assertEq(price2, 2.2 ether);
        (uint256 price3,) = _redeemToken(user);
        assertEq(price3, 2.2 ether);
        assertEq(tokenizer.pooledRep(GENESIS_UID), 0);
    }

    function test_Redeem_FloorDustStaysInPool() public {
        // Make the pool indivisible by the supply: 3 tokens at 1.1 REP plus one at a 1-wei price
        // (1-wei fee → premium floors to 1 wei), so pool = 3.3e18 + 1 over 4 tokens.
        _mintTokens(user, 3);
        assertEq(tokenizer.pooledRep(GENESIS_UID), 3.3 ether);
        feeCtl.setFee(1);
        _mintTokens(user, 1); // pool = 3.3e18 + 1 wei, supply 4

        uint256 pooled = tokenizer.pooledRep(GENESIS_UID);
        uint256 expectedPrice = pooled / 4; // floors: the +1 wei is not divisible by 4

        (uint256 price,) = _redeemToken(user);
        assertEq(price, expectedPrice);
        // The remaining 3 tokens are backed by 3 × the average plus exactly the 1-wei dust.
        assertEq(tokenizer.pooledRep(GENESIS_UID), expectedPrice * 3 + 1);
    }

    function test_Redeem_CountsDemandVolume() public {
        _mintTokens(user, 1);

        uint256 previewBefore = _previewUncappedFee();

        _redeemToken(user);

        // The redemption registered as demand: the same-block preview strictly rises.
        assertGt(_previewUncappedFee(), previewBefore);
    }

    function test_RevertWhen_Redeem_OracleRejectsQuery_PrepaidRightSurvives() public {
        _mintTokens(user, 1);
        string memory tooLong = string(new bytes(uint256(multiverse.MAX_QUERY_LENGTH()) + 1));

        // The oracle's rejection bubbles through redeem untouched (no try/catch), rolling back the
        // burn and the pool decrement: a bad parameter cannot destroy the prepaid right.
        vm.prank(user);
        vm.expectRevert(Multiverse.QueryTooLong.selector);
        tokenizer.redeem(GENESIS_UID, tooLong, DEFAULT_NUMBER_OF_OUTCOMES);

        assertEq(_genesisQueryToken().balanceOf(user), tokenizer.ONE_QUERY());
        assertEq(tokenizer.pooledRep(GENESIS_UID), 1.1 ether);
        assertEq(multiverse.queryCount(), 0);

        // The next redeem is successful.
        _redeemToken(user);
    }

    function test_Redeem_VolumeParityWithDirectQuery() public {
        _mintTokens(user, 1);

        // A direct query and a redemption must move future fees identically.
        uint256 snapshot = vm.snapshotState();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        uint256 previewAfterDirect = _previewUncappedFee();
        vm.revertToState(snapshot);

        _redeemToken(user);
        assertEq(_previewUncappedFee(), previewAfterDirect);
    }

    /*//////////////////////////////////////////////////////////////
                                MIGRATE
    //////////////////////////////////////////////////////////////*/
    function test_RevertWhen_Migrate_NotImplemented() public {
        vm.prank(user);
        vm.expectRevert(QueryTokenizer.MigrationNotImplemented.selector);
        tokenizer.migrate(GENESIS_UID, GENESIS_UID + 1, 1);
    }

    /*//////////////////////////////////////////////////////////////
                               QUERY TOKEN
    //////////////////////////////////////////////////////////////*/
    function test_QueryToken_Metadata() public {
        _mintTokens(user, 1);
        QueryToken queryToken = _genesisQueryToken();

        assertEq(queryToken.name(), "Lituus Query Token");
        assertEq(queryToken.symbol(), "QT");
        assertEq(queryToken.decimals(), 18);
        assertEq(queryToken.owner(), address(tokenizer));
    }

    function test_RevertWhen_QueryToken_MintNotOwner() public {
        _mintTokens(user, 1);
        QueryToken queryToken = _genesisQueryToken();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        queryToken.mint(user, 1e18);
    }

    function test_RevertWhen_QueryToken_BurnNotOwner() public {
        _mintTokens(user, 1);
        QueryToken queryToken = _genesisQueryToken();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        queryToken.burn(user, 1e18);
    }
}
