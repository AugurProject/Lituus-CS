// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { IReputationToken } from "src/interfaces/IReputationToken.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";
import { MockERC20 } from "src/mock/MockERC20.sol";
import { MockZoltar } from "src/mock/MockZoltar.sol";
import { MockZoltarQuestionData } from "src/mock/MockZoltarQuestionData.sol";
import { MockQueryFeeController } from "src/mock/MockQueryFeeController.sol";

/// @notice Protocol deployment fixture: mocks + Multiverse wired at START_TIME, no funding.
/// @dev The bottom fixture layer. It deploys the protocol and nothing else — balances are the
///      responsibility of the layers (or suites) above, so a suite's economics can never drift
///      because an unrelated suite changed the shared funding. Suites that need a different fee
///      controller override `_deployFeeController` (and `_afterProtocolDeploy` for post-wiring)
///      instead of rewriting the deployment.
abstract contract MultiverseDeployFixture is Test {
    // Nonzero on purpose: Lituus universe ids mirror Zoltar universe ids, and a nonzero genesis
    // catches any code path that wrongly assumes the genesis universe lives at id 0.
    uint248 internal constant GENESIS_UID = 42;
    uint256 internal constant DEFAULT_FEE = 1 ether;
    uint256 internal constant USER_REP_BALANCE = 1000 ether;
    uint8 internal constant DEFAULT_NUMBER_OF_OUTCOMES = 3;
    // Readable outcome pair for escalation ping-pong (both valid for the default query).
    uint8 internal constant OUTCOME_A = 1;
    uint8 internal constant OUTCOME_B = 2;
    string internal constant DEFAULT_QUESTION = "John Doe's pet?[CAT,DOG,SHARK]";
    // Fixed timestamp so queryCreateTime / forkTime assertions are deterministic.
    uint256 internal constant START_TIME = 1_000_000;

    MockERC20 internal underlying;
    MockZoltarQuestionData internal zoltarQuestionData;
    MockZoltar internal zoltar;
    // Set by the default _deployFeeController; suites overriding the hook leave it unset.
    MockQueryFeeController internal feeCtl;
    Multiverse internal multiverse;
    ILituusRep internal genesisRep;

    address internal user = makeAddr("user");
    address internal bystander = makeAddr("bystander");
    address internal challenger = makeAddr("challenger");
    // Stub address for the query tokenizer: the Multiverse requires it nonzero, but these suites do
    // not test the tokenizer (they use it only to satisfy the constructor).
    address internal queryTokenizerStub = makeAddr("queryTokenizer");

    /// @dev The genesis universe's fork threshold in wREP shares, derived independently of the
    ///      Multiverse's own conversion (straight through Zoltar + the vault).
    function _forkThresholdWrep() internal view returns (uint256) {
        return genesisRep.convertToShares(zoltar.getForkThreshold(GENESIS_UID));
    }

    /// @dev The genesis universe's query fee cap: half the wREP fork threshold.
    function _queryFeeCapWrep() internal view returns (uint256) {
        return _forkThresholdWrep() / 2;
    }

    /// @dev The genesis universe's uncapped demand-inclusive query fee, read off the production
    ///      mint-pricing bundle.
    function _previewUncappedFee() internal view returns (uint256 fee) {
        (fee,,) = multiverse.getMintPricing(GENESIS_UID);
    }

    /// @dev Deploys the protocol at START_TIME. Funds nothing.
    function setUp() public virtual {
        vm.warp(START_TIME);

        underlying = new MockERC20("Underlying", "U");
        zoltarQuestionData = new MockZoltarQuestionData();
        zoltar = new MockZoltar(IReputationToken(address(underlying)), zoltarQuestionData);
        IQueryFeeController controller = _deployFeeController();
        multiverse = _deployMultiverse(controller);

        (ILituusRep repToken,,,,,,,,,,,,) = multiverse.universes(GENESIS_UID);
        genesisRep = repToken;

        _afterProtocolDeploy();
    }

    /// @dev Fee controller hook: the mock with a settable flat fee by default. Suites that need the
    ///      production controller override this (deploy order: controller first, then the Multiverse).
    function _deployFeeController() internal virtual returns (IQueryFeeController) {
        feeCtl = new MockQueryFeeController(DEFAULT_FEE);
        return IQueryFeeController(address(feeCtl));
    }

    /// @dev Post-deploy hook, runs after the Multiverse exists. Empty by default; the production
    ///      controller suite wires `setMultiverse` here.
    function _afterProtocolDeploy() internal virtual { }

    /// @dev Multiverse deploy hook: the production contract by default. Suites that need a test
    ///      harness (e.g. exposing internal views) override this.
    function _deployMultiverse(IQueryFeeController controller) internal virtual returns (Multiverse) {
        return new Multiverse(zoltar, GENESIS_UID, controller, queryTokenizerStub);
    }

    /// @dev Funding tool (not invoked here): mint underlying, wrap into REP, approve the multiverse.
    function _fundWithRep(address account, uint256 amount) internal {
        underlying.mint(account, amount);
        vm.startPrank(account);
        underlying.approve(address(genesisRep), type(uint256).max);
        genesisRep.approve(address(multiverse), type(uint256).max);
        multiverse.wrap(GENESIS_UID, amount, 0);
        vm.stopPrank();
    }

    /// @dev The claim payout the contract owes for a stake, from the totals frozen at resolution.
    ///      NOTE: this re-derives the contract's own payout formula, so it can never catch a bug
    ///      in that formula — it exists for dynamic-fee and fuzz cases where a literal cannot be
    ///      pinned. Tests in the literal-convention suites must assert hand-computed literals.
    ///      Lives on the deploy layer so the unit and fuzz suites share one definition.
    function _expectedPayout(uint256 queryId, uint256 stakeIndex) internal view returns (uint256) {
        Multiverse.Stake memory stake = multiverse.getStakes(GENESIS_UID, queryId)[stakeIndex];
        (,, uint96 totalDistributable, uint96 winnerStaked) = multiverse.queryResolutions(GENESIS_UID, queryId);
        return stake.amount + stake.amount * uint256(totalDistributable) / uint256(winnerStaked);
    }
}

/// @notice Funded functional fixture: the deploy layer plus the three standard actors funded, and
///         the behavioral step helpers used by the functional suites.
/// @dev Amounts here serve the functional suites (createQuery/report/resolve), which only need
///      actors with enough REP; suites with economic assumptions (stress, spikes) must NOT inherit
///      this layer — they extend MultiverseDeployFixture and pin their own economy.
abstract contract MultiverseFixtures is MultiverseDeployFixture {
    function setUp() public virtual override {
        super.setUp();

        _fundWithRep(user, USER_REP_BALANCE);
        _fundWithRep(bystander, USER_REP_BALANCE);
        _fundWithRep(challenger, USER_REP_BALANCE);
    }

    /// @dev Query creation fixture: `user` creates a default query in the genesis universe.
    /// @return queryId The id of the created query.
    function _createDefaultQuery() internal returns (uint256 queryId) {
        queryId = multiverse.queryCount();
        uint256 userBalanceBefore = genesisRep.balanceOf(user);
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));
        uint256 queryCountBefore = multiverse.queryCount();

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        assertEq(multiverse.queryCount(), queryCountBefore + 1);
        assertGt(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore);
        assertLt(genesisRep.balanceOf(user), userBalanceBefore);
    }

    /// @dev Report fixture: `reporter` reports `outcome` on `queryId` in the genesis universe,
    ///      asserting the stake recording (record appended with exact fields) and the REP movement
    ///      (reporter pays exactly the required stake, the multiverse receives it).
    function _report(address reporter, uint256 queryId, uint8 outcome) internal {
        (uint256 requiredStake,) = multiverse.getNextRequiredStake(GENESIS_UID, queryId);
        uint256 reporterBalanceBefore = genesisRep.balanceOf(reporter);
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));
        uint256 stakeCountBefore = multiverse.getStakes(GENESIS_UID, queryId).length;

        vm.prank(reporter);
        multiverse.report(GENESIS_UID, queryId, outcome);

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        assertEq(stakes.length, stakeCountBefore + 1);
        Multiverse.Stake memory newStake = stakes[stakes.length - 1];
        assertEq(newStake.reporter, reporter);
        assertEq(newStake.time, uint48(vm.getBlockTimestamp()));
        assertEq(newStake.reportedOutcome, outcome);
        assertEq(newStake.amount, requiredStake);
        assertEq(genesisRep.balanceOf(reporter), reporterBalanceBefore - requiredStake);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore + requiredStake);
    }

    /// @dev Reported query fixture: `user` creates a default query and places the first report on it.
    /// @return queryId The id of the created and reported query.
    function _createReportedQuery(uint8 outcome) internal returns (uint256 queryId) {
        queryId = _createDefaultQuery();
        _report(user, queryId, outcome);
    }

    /// @dev Warps to one second past the query's 3-day reporting window — the earliest moment an
    ///      unreported query becomes resolvable (as INVALID).
    function _warpPastReportingWindow(uint256 queryId) internal {
        (uint48 queryCreateTime,,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
        vm.warp(uint256(queryCreateTime) + multiverse.THREE_DAYS() + 1);
    }

    /// @dev Warps to one second past the last stake's 1-day appeal window — the earliest moment a
    ///      reported query becomes resolvable.
    function _warpPastAppealWindow(uint256 queryId) internal {
        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
        vm.warp(uint256(stakes[stakes.length - 1].time) + multiverse.ONE_DAY() + 1);
    }

    /// @dev Expired query fixture: `user` creates a default query that is never reported, then time
    ///      passes the reporting window, so it is resolvable as INVALID.
    /// @return queryId The id of the created and expired query.
    function _createExpiredQuery() internal returns (uint256 queryId) {
        queryId = _createDefaultQuery();
        _warpPastReportingWindow(queryId);
    }

    /// @dev Resolvable reported query fixture: `user` creates a default query, places the first
    ///      report on it, and time passes the appeal window, so it is resolvable to `outcome`.
    /// @return queryId The id of the created, reported, and resolvable query.
    function _createResolvableReportedQuery(uint8 outcome) internal returns (uint256 queryId) {
        queryId = _createReportedQuery(outcome);
        _warpPastAppealWindow(queryId);
    }

    /// @dev Resolve fixture: `resolver` resolves `queryId` in the genesis universe, asserting the
    ///      resolution record left UNRESOLVED and that getOutcome agrees with it.
    /// @return outcome The outcome the query resolved to.
    function _resolve(address resolver, uint256 queryId) internal returns (uint8 outcome) {
        vm.prank(resolver);
        multiverse.resolve(GENESIS_UID, queryId);

        (, outcome,,) = multiverse.queryResolutions(GENESIS_UID, queryId);
        assertTrue(outcome != multiverse.UNRESOLVED());
        assertEq(multiverse.getOutcome(GENESIS_UID, queryId), outcome);
    }

    /// @dev Escalation ladder fixture: each reporter in turn reports their outcome on `queryId`,
    ///      12 hours after the previous step — within the first-report window and every appeal window.
    function _escalateChain(uint256 queryId, address[] memory reporters, uint8[] memory outcomes) internal {
        assertEq(reporters.length, outcomes.length, "escalateChain: length mismatch");
        for (uint256 i = 0; i < reporters.length; i++) {
            vm.warp(vm.getBlockTimestamp() + 12 hours);
            _report(reporters[i], queryId, outcomes[i]);

            Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, queryId);
            assertEq(stakes.length, i + 1);
        }
    }

    /// @dev Reported ladder fixture: the canonical multi-stake escalation — user→A, challenger→B,
    ///      bystander→A — past its appeal window, so it is ready to resolve to OUTCOME_A with two
    ///      winning stakes (indices 0 and 2, amounts fee and 4*fee) and one losing stake (index 1,
    ///      amount 2*fee); `user` is the first winning reporter, so resolve() will push-pay them
    ///      the reporter reward. The first report lands 18 hours in, so the reward ramp is exactly
    ///      a quarter of the fee (18h / THREE_DAYS) and reward-derived literals stay clean.
    /// @return queryId The id of the reported, resolvable query.
    function _createReportedLadder() internal returns (uint256 queryId) {
        queryId = _createDefaultQuery();

        vm.warp(vm.getBlockTimestamp() + 18 hours);
        _report(user, queryId, OUTCOME_A);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        _report(challenger, queryId, OUTCOME_B);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        _report(bystander, queryId, OUTCOME_A);

        _warpPastAppealWindow(queryId);
    }

    /// @dev Resolved ladder fixture: the canonical reported ladder (see _createReportedLadder),
    ///      resolved to OUTCOME_A.
    /// @return queryId The id of the resolved query.
    function _createResolvedLadder() internal returns (uint256 queryId) {
        queryId = _createReportedLadder();
        assertEq(_resolve(user, queryId), OUTCOME_A);
    }

    /// @dev Near-threshold ladder fixture: a query at fee = forkThreshold / 8 escalated in its
    ///      creation block through t/8 (user, A) and t/4 (challenger, B) to t/2 (bystander, A) —
    ///      the exact-half stake is the largest placeable one (the stake rule clamps only stakes
    ///      strictly ABOVE half), so the ladder ends one step from the fork level: the next
    ///      required stake is exactly the full fork threshold.
    /// @return queryId The id of the reported query.
    /// @return forkThreshold The universe's fork threshold at build time.
    function _createNearThresholdLadder() internal returns (uint256 queryId, uint256 forkThreshold) {
        forkThreshold = _forkThresholdWrep();
        // The fixture supply keeps forkThreshold divisible by 8, so the doubling lands exactly
        // on half the threshold with no rounding drift.
        uint256 fee = forkThreshold / 8;
        assertEq(fee * 8, forkThreshold, "fixture supply must keep threshold/8 exact");
        feeCtl.setFee(fee);

        queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        _report(user, queryId, OUTCOME_A); // t/8
        _report(challenger, queryId, OUTCOME_B); // t/4
        _report(bystander, queryId, OUTCOME_A); // exactly t/2 — ordinary, not clamped
    }

    /// @dev Claim fixture: `claimant` claims their stake at `stakeIndex` on the resolved `queryId`,
    ///      asserting the exact payout (stake plus its pro-rata share of the distributable losing
    ///      stakes, from the totals frozen at resolution), the StakeClaimed event, the REP movement,
    ///      and that the stake's amount is zeroed (the settled flag).
    /// @return payout The amount the claim paid out.
    function _claim(address claimant, uint256 queryId, uint256 stakeIndex) internal returns (uint256 payout) {
        uint256 expectedPayout = _expectedPayout(queryId, stakeIndex);

        uint256 claimantBalanceBefore = genesisRep.balanceOf(claimant);
        uint256 multiverseBalanceBefore = genesisRep.balanceOf(address(multiverse));

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.StakeClaimed(claimant, GENESIS_UID, queryId, stakeIndex, expectedPayout);
        vm.prank(claimant);
        multiverse.claim(GENESIS_UID, queryId, stakeIndex);

        assertEq(genesisRep.balanceOf(claimant), claimantBalanceBefore + expectedPayout);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBalanceBefore - expectedPayout);
        assertEq(multiverse.getStakes(GENESIS_UID, queryId)[stakeIndex].amount, 0);

        return expectedPayout;
    }
}
