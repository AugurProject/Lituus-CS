// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { QueryFeeController } from "src/QueryFeeController.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { IReputationToken } from "src/interfaces/IReputationToken.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";
import { MockERC20 } from "src/mock/MockERC20.sol";
import { MockZoltar } from "src/mock/MockZoltar.sol";
import { MockZoltarQuestionData } from "src/mock/MockZoltarQuestionData.sol";
import { MultiverseDeployFixture } from "./Multiverse.fixtures.sol";

/// @notice Shared expected-fee math for the query fee suites.
/// @dev Mirrors the contract's integer operations (same order, same floors), so expected values are
///      derived from scenario parameters instead of being hardcoded.
abstract contract QueryFeeTestHelpers is MultiverseDeployFixture {
    /// @dev Warps to window `window` with `elapsed` seconds of it gone by.
    function _warpToWindow(uint256 window, uint256 elapsed) internal {
        vm.warp(multiverse.GENESIS_TIMESTAMP() + window * multiverse.THREE_DAYS() + elapsed);
    }

    /// @dev Creates a query as `user` and returns the fee actually charged (balance delta).
    function _chargedFee() internal returns (uint256 chargedFee) {
        uint256 balanceBefore = genesisRep.balanceOf(user);
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        chargedFee = balanceBefore - genesisRep.balanceOf(user);
    }

    /// @dev Mirror of `_calculateCurveModifier`.
    function _curveModifier(uint256 sixty, uint256 recent) internal view returns (uint256 modifier_) {
        uint256 scale = multiverse.SCALE();
        uint256 ratio = sixty == 0 ? scale : 20 * recent * scale / sixty;

        if (ratio >= scale) {
            modifier_ = (4 * scale) / 5 + ratio / 5;
        } else {
            uint256 shortage = scale - ratio;
            uint256 powered = scale;
            for (uint256 i = 0; i < 6; i++) {
                powered = powered * shortage / scale;
            }
            modifier_ = scale * scale / (scale + 100 * powered);
        }
    }

    /// @dev The deepest down-curve point: an empty recent window over any nonzero sixty.
    function _floorModifier() internal view returns (uint256) {
        return _curveModifier(1, 0);
    }

    /// @dev Mirror of `_calculateFeeAndApplyVolume`'s local-volume math, both regimes. Volumes are
    ///      the test-known query counts. The mirror predicts the UNCAPPED fee: the half-fork-threshold
    ///      cap applied by createQuery is asserted directly in the fee-cap tests, never mirrored.
    /// @param baseFee The controller base fee the modifier applies to.
    /// @param windowId The current window id.
    /// @param fractionElapsed Fraction of the current window elapsed, SCALE-scaled.
    /// @param currentVol Real query count already in window `windowId`.
    /// @param prevVol Real query count in window `windowId-1` (ignored for windowId == 0: bootstrap is used).
    /// @param sixtyStorage The real running sum of windows windowId-1..windowId-20 (universeStatistics value).
    /// @param oldestVol Real query count in window `windowId-20` (only read in the real regime, windowId >= 20).
    function _expectedFee(
        uint256 baseFee,
        uint256 windowId,
        uint256 fractionElapsed,
        uint256 currentVol,
        uint256 prevVol,
        uint256 sixtyStorage,
        uint256 oldestVol
    ) internal view returns (uint256) {
        uint256 scale = multiverse.SCALE();
        uint256 boot = multiverse.BOOT_VOLUME();

        uint256 previous = windowId >= 1 ? prevVol : boot;
        uint256 recent = currentVol + (scale - fractionElapsed) * previous / scale;

        uint256 sixty = currentVol + sixtyStorage;
        if (windowId >= 20) {
            // Real regime: the oldest window's elapsed tail has rolled out of the 60-day span.
            sixty -= fractionElapsed * oldestVol / scale;
        } else {
            // Bootstrap regime: top up the missing pre-genesis windows, oldest one trimmed.
            sixty += (20 - windowId - 1) * boot + (scale - fractionElapsed) * boot / scale;
        }

        return baseFee * _curveModifier(sixty, recent) / scale;
    }
}

/// @notice Unit suite for the per-query demand modifier (volume windows, interpolation, bootstrap).

/// @notice Unit suite for the per-query demand modifier (volume windows, interpolation, bootstrap).
/// @dev Uses the mock controller from the deploy fixture; only `user` is funded — the modifier
///      tests have no other actors and no economic assumptions beyond the base fee constant.
contract MultiverseQueryFeeTest is QueryFeeTestHelpers {
    function setUp() public override {
        super.setUp();

        _fundWithRep(user, USER_REP_BALANCE);
    }

    function test_QueryFee_FirstQueryAtGenesisIsNeutral() public {
        // At genesis (w = 0, f = 0, zero volume) the bootstrap makes the recent window exactly 1/20
        // of the sixty-day window: ratio 1.0, modifier 1.0, fee = base. This also proves the query
        // never prices itself: were it counted before pricing, the ratio would exceed 1.0 and the
        // charge would exceed the base.
        assertEq(_chargedFee(), DEFAULT_FEE);
    }

    function test_QueryFee_ChargedFeeIsStoredOnTheQuery() public {
        uint256 charged = _chargedFee();

        (,, uint256 storedFee,) = multiverse.queries(0);
        assertEq(storedFee, charged);
    }

    function test_QueryFee_SecondQuerySameInstantCostsMore() public {
        uint256 first = _chargedFee();

        // The first query is now in the current bucket: one real query on top of the bootstrap.
        uint256 second = _chargedFee();

        assertEq(second, _expectedFee(DEFAULT_FEE, 0, 0, 1, 0, 0, 0));
        assertGt(second, first);
    }

    function test_QueryFee_FeeIncreasesMonotonicallyWithVolume() public {
        uint256 previous = 0;
        for (uint256 i = 0; i < 5; i++) {
            uint256 charged = _chargedFee();
            assertGe(charged, previous);
            previous = charged;
        }
    }

    function test_QueryFee_IdleMidWindowDipsBelowBase() public {
        // Half the genesis window with zero real volume: recent decays below the bootstrap average
        // and the steep down-branch prices below base.
        _warpToWindow(0, multiverse.THREE_DAYS() / 2);

        uint256 charged = _chargedFee();

        assertEq(charged, _expectedFee(DEFAULT_FEE, 0, multiverse.SCALE() / 2, 0, 0, 0, 0));
        // Hand-derived anchor: recent = floor(0.5 * 3) = 1, sixty = 57 + floor(0.5 * 3) = 58,
        // ratio = 20/58, modifier = 1e36 / (1e18 + 100 * (1e18 - 20e18/58)^6 / 1e18^5), every
        // intermediate floored -> fee = 112243280195776293 wei.
        assertEq(charged, 112_243_280_195_776_293);
        assertLt(charged, DEFAULT_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                            WINDOW ROLLOVER
    //////////////////////////////////////////////////////////////*/
    function test_QueryFee_RolloverCarriesCompletedWindowIntoSixty() public {
        // Three queries in window 0, then the first query of window 1: the 3 real queries in vol[0]
        // replace exactly the BOOT_VOLUME bootstrap ones in both the recent tail and the sixty-day
        // sum, so the fee is neutral again — precisely the base.
        _chargedFee();
        _chargedFee();
        _chargedFee();

        _warpToWindow(1, 0);
        uint256 charged = _chargedFee();

        assertEq(charged, _expectedFee(DEFAULT_FEE, 1, 0, 0, 3, 3, 0));
        assertEq(charged, DEFAULT_FEE);

        (uint128 sixtyDayVolume, uint128 lastWindowId) = multiverse.universeStatistics(GENESIS_UID);
        assertEq(sixtyDayVolume, 3);
        assertEq(lastWindowId, 1);
    }

    function test_QueryFee_MultiWindowStepRollover() public {
        // Volume in windows 0 and 1, priced at the start of window 3: the step loop folds both
        // buckets into the running sum, and the recent tail reads the empty window 2 -> recent 0 ->
        // the down-curve floor.
        _chargedFee();
        _warpToWindow(1, 0);
        _chargedFee();

        _warpToWindow(3, 0);
        uint256 charged = _chargedFee();

        assertEq(charged, _expectedFee(DEFAULT_FEE, 3, 0, 0, 0, 2, 0));
        assertEq(charged, DEFAULT_FEE * _floorModifier() / multiverse.SCALE());

        (uint128 sixtyDayVolume, uint128 lastWindowId) = multiverse.universeStatistics(GENESIS_UID);
        assertEq(sixtyDayVolume, 2);
        assertEq(lastWindowId, 3);
    }

    function test_QueryFee_LongIdleGapRecomputesToNeutral() public {
        // Volume in window 0, then idle past the whole 60-day span (gap >= 20): the recompute finds
        // only empty real windows, sixty = 0, and an empty sixty prices neutral (1.0) by design.
        _chargedFee();
        _chargedFee();

        _warpToWindow(25, 0);
        assertEq(_chargedFee(), DEFAULT_FEE);

        (uint128 sixtyDayVolume, uint128 lastWindowId) = multiverse.universeStatistics(GENESIS_UID);
        assertEq(sixtyDayVolume, 0);
        assertEq(lastWindowId, 25);
    }

    /*//////////////////////////////////////////////////////////////
                    EMPTY WINDOWS ACROSS THE UNIVERSE'S LIFE
    //////////////////////////////////////////////////////////////*/
    function test_QueryFee_EmptyWindowsInBootstrapEra() public {
        // Windows 0-4 fully idle, priced at the start of window 5. The bootstrap keeps the sixty-day
        // side afloat, but the recent tail reads the real (empty) window 4: only window 0 ever has a
        // bootstrap tail. Idle early life therefore prices at the down-curve floor, not at neutral.
        _warpToWindow(5, 0);

        uint256 charged = _chargedFee();

        assertEq(charged, _expectedFee(DEFAULT_FEE, 5, 0, 0, 0, 0, 0));
        assertEq(charged, DEFAULT_FEE * _floorModifier() / multiverse.SCALE());

        (uint128 sixtyDayVolume, uint128 lastWindowId) = multiverse.universeStatistics(GENESIS_UID);
        assertEq(sixtyDayVolume, 0);
        assertEq(lastWindowId, 5);
    }

    function test_QueryFee_RealRegimeSubtractsOldestTailInterpolated() public {
        // First run of the real-regime branch with a nonzero oldest window: volume in window 0 (2
        // queries) and window 19 (3 queries), priced mid-window 20 (f = 0.5). Half of vol[0] has
        // rolled out of the 60-day span: sixty = 5 - floor(0.5 * 2) = 4 while recent = floor(0.5 * 3)
        // = 1, landing the ratio on the up-branch. Without the subtraction the mirror (and the fee)
        // would come out lower — the tail removal is directly observable.
        _chargedFee();
        _chargedFee();

        _warpToWindow(19, 0);
        _chargedFee();
        _chargedFee();
        _chargedFee();

        _warpToWindow(20, multiverse.THREE_DAYS() / 2);
        uint256 charged = _chargedFee();

        assertEq(charged, _expectedFee(DEFAULT_FEE, 20, multiverse.SCALE() / 2, 0, 3, 5, 2));
        // Hand-derived anchor: recent = floor(0.5 * 3) = 1, sixty = 5 - floor(0.5 * 2) = 4,
        // ratio = 20 * 1 / 4 = 5.0 -> modifier = 0.8 + 5.0 / 5 = 1.8 -> fee = 1.8 REP.
        assertEq(charged, 1.8 ether);
        assertGt(charged, DEFAULT_FEE);

        (uint128 sixtyDayVolume, uint128 lastWindowId) = multiverse.universeStatistics(GENESIS_UID);
        assertEq(sixtyDayVolume, 5);
        assertEq(lastWindowId, 20);
    }

    function test_QueryFee_EmptyWindowsInTheMiddle() public {
        // Volume in window 0, windows 1-2 idle, volume in window 3, priced at the start of window 4:
        // the step rollover folds both volume blocks into the running sum, the idle gap contributes
        // zero, and the recent tail reads only window 3.
        _chargedFee();
        _chargedFee();

        _warpToWindow(3, 0);
        _chargedFee();

        _warpToWindow(4, 0);
        uint256 charged = _chargedFee();

        assertEq(charged, _expectedFee(DEFAULT_FEE, 4, 0, 0, 1, 3, 0));

        (uint128 sixtyDayVolume, uint128 lastWindowId) = multiverse.universeStatistics(GENESIS_UID);
        assertEq(sixtyDayVolume, 3);
        assertEq(lastWindowId, 4);
    }

    function test_QueryFee_TrailingIdleDecaysGradually() public {
        // Volume in window 0, then idle into window 1: the recent tail (1 - f) * vol[0] fades
        // continuously with f instead of dropping at the window edge. Probed at f = 0.25 and
        // f = 0.75 — the second probe accounts for the first one now sitting in window 1's bucket.
        _chargedFee();
        _chargedFee();
        _chargedFee();
        _chargedFee();

        _warpToWindow(1, multiverse.THREE_DAYS() / 4);
        uint256 earlyProbe = _chargedFee();
        assertEq(earlyProbe, _expectedFee(DEFAULT_FEE, 1, multiverse.SCALE() / 4, 0, 4, 4, 0));

        _warpToWindow(1, 3 * multiverse.THREE_DAYS() / 4);
        uint256 lateProbe = _chargedFee();
        assertEq(lateProbe, _expectedFee(DEFAULT_FEE, 1, 3 * multiverse.SCALE() / 4, 1, 4, 4, 0));
        // Hand-derived anchor: recent = 1 + floor(0.25 * 4) = 2, sixty = 1 + 4 + 54 + floor(0.25 * 3)
        // = 59, ratio = 40/59 on the down-branch -> fee = 899657120952168936 wei.
        assertEq(lateProbe, 899_657_120_952_168_936);

        assertLt(lateProbe, earlyProbe);
    }

    function test_QueryFee_EmptySixtyBoundary_BeforeTheCliff() public {
        // Identical history to the After test: volume only in window 0, then full idle. Priced at the
        // start of window 20, vol[0] is still inside the 60-day span, so sixty > 0 with recent = 0:
        // the down-curve floor applies.
        _chargedFee();
        _chargedFee();

        _warpToWindow(20, 0);
        uint256 charged = _chargedFee();

        assertEq(charged, DEFAULT_FEE * _floorModifier() / multiverse.SCALE());
    }

    function test_QueryFee_EmptySixtyBoundary_AfterTheCliff() public {
        // Same history, one window later: vol[0] has rolled fully out, the recompute leaves sixty at
        // zero, and an empty sixty prices neutral by design. Together with the Before test this pins
        // the 101x discontinuity between windows 20 and 21 of an idle universe — any future smoothing
        // must show up as a deliberate change here.
        _chargedFee();
        _chargedFee();

        _warpToWindow(21, 0);
        uint256 charged = _chargedFee();

        assertEq(charged, DEFAULT_FEE);

        (uint128 sixtyDayVolume, uint128 lastWindowId) = multiverse.universeStatistics(GENESIS_UID);
        assertEq(sixtyDayVolume, 0);
        assertEq(lastWindowId, 21);
    }

    function test_QueryFee_BootstrapToRealHandoffIsSeamless() public {
        // Steady baseline demand (exactly BOOT_VOLUME queries per window) from genesis through the
        // real regime: the first query of every window prices exactly neutral, including across the
        // bootstrap-to-real handoff at window 20 — real data replaces the bootstrap with no step.
        uint256 boot = multiverse.BOOT_VOLUME();

        for (uint256 w = 0; w <= 20; w++) {
            _warpToWindow(w, 0);
            assertEq(_chargedFee(), DEFAULT_FEE);
            for (uint256 i = 1; i < boot; i++) {
                _chargedFee();
            }
        }

        _warpToWindow(21, 0);
        assertEq(_chargedFee(), DEFAULT_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE VALIDATIONS
    //////////////////////////////////////////////////////////////*/
    function test_QueryFee_RevertsOnZeroFinalFee() public {
        feeCtl.setFee(0);

        vm.prank(user);
        vm.expectRevert(Multiverse.ZeroFee.selector);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
    }

    /*//////////////////////////////////////////////////////////////
                    FEE CAP (HALF THE FORK THRESHOLD)
    //////////////////////////////////////////////////////////////*/
    function test_QueryFee_ClampsFeeToHalfForkThreshold() public {
        // Successor of the removed FeeAboveForkThreshold revert test: a base fee ABOVE the cap no
        // longer blocks creation — the query is created and charged exactly half the fork threshold
        // (= 1% of supply, imkharn's cap). With this suite's supply (1000e18, threshold supply/20)
        // the cap is 25e18; the base is set to double that so the clamp is observable, not a no-op.
        uint256 cap = zoltar.getForkThreshold(GENESIS_UID) / 2;
        feeCtl.setFee(2 * cap);

        uint256 chargedFee = _chargedFee();

        assertEq(chargedFee, cap);
        (,, uint256 storedFee,) = multiverse.queries(0);
        assertEq(storedFee, cap);
    }

    function test_QueryFee_FeeJustBelowCapIsUntouched() public {
        // The cap's lower boundary: a base one wei below the cap (genesis-neutral modifier is exactly
        // 1.0) is charged unchanged — the cap never touches legal fees.
        uint256 cap = zoltar.getForkThreshold(GENESIS_UID) / 2;
        feeCtl.setFee(cap - 1);

        uint256 chargedFee = _chargedFee();

        assertEq(chargedFee, cap - 1);
        (,, uint256 storedFee,) = multiverse.queries(0);
        assertEq(storedFee, cap - 1);
    }

    function test_QueryFee_ModifierPushesFeeIntoCap() public {
        // The cap also catches the DYNAMIC overshoot: a perfectly legal base (cap / 2) crosses the
        // cap once the demand modifier passes 2.0x. Queries are created while the predicted uncapped
        // fee is still below the cap; the first query predicted at or over it is created charged
        // exactly the cap.
        uint256 cap = zoltar.getForkThreshold(GENESIS_UID) / 2;
        uint256 base = cap / 2;
        feeCtl.setFee(base);

        uint256 volume = 0;
        while (_expectedFee(base, 0, 0, volume, 0, 0, 0) < cap) {
            _chargedFee();
            volume++;
        }

        assertEq(_chargedFee(), cap);
    }

    function test_QueryFee_CappedQueryStillCountsAsVolume() public {
        // The cap clamps the price, not the demand signal: a capped query must still enter the
        // volume bucket. Proven behaviorally — after one capped query, a small base prices strictly
        // above neutral, matching the mirror with currentVol = 1. If the capped query were not
        // counted, the second charge would be exactly DEFAULT_FEE.
        uint256 cap = zoltar.getForkThreshold(GENESIS_UID) / 2;
        feeCtl.setFee(2 * cap);
        assertEq(_chargedFee(), cap);

        feeCtl.setFee(DEFAULT_FEE);
        uint256 chargedFee = _chargedFee();

        assertEq(chargedFee, _expectedFee(DEFAULT_FEE, 0, 0, 1, 0, 0, 0));
        assertGt(chargedFee, DEFAULT_FEE);
    }

    function test_QueryFee_CappedFeeQueryIsReportable() public {
        // Regression pin for the fee-cap boundary (the `>` fix in the stake rule): a query whose
        // fee was capped to exactly half the fork threshold must accept its first report as an
        // ORDINARY stake. The required stake equals the capped fee and stays strictly below the
        // fork threshold; under the pre-fix `>=` stake rule this exact report escalated to the
        // full threshold and reverted with ForkingNotImplemented, making capped queries dead on
        // arrival. Lives here rather than the report suite to keep the cap tests self-contained.
        uint256 cap = zoltar.getForkThreshold(GENESIS_UID) / 2;
        feeCtl.setFee(2 * cap);
        assertEq(_chargedFee(), cap);

        (uint256 requiredStakeAmount, uint256 forkThreshold) = multiverse.getNextRequiredStake(GENESIS_UID, 0);
        assertEq(requiredStakeAmount, cap);
        assertEq(forkThreshold, zoltar.getForkThreshold(GENESIS_UID));
        assertLt(requiredStakeAmount, forkThreshold);

        vm.prank(user);
        multiverse.report(GENESIS_UID, 0, OUTCOME_A);

        Multiverse.Stake[] memory stakes = multiverse.getStakes(GENESIS_UID, 0);
        assertEq(stakes.length, 1);
        assertEq(stakes[0].amount, cap);
    }

    /*//////////////////////////////////////////////////////////////
                          CONTROLLER COUPLING
    //////////////////////////////////////////////////////////////*/
    function test_QueryFee_BootProfitDerivedFromControllerInitialFee() public view {
        assertEq(multiverse.BOOT_PROFIT(), 2 * feeCtl.INITIAL_BASE_FEE());
    }
}

/// @notice Stress suite for the fee algorithm's limits, on a pinned economy.
/// @dev Extends the deploy fixture directly and defines its own funding, so the numbers below are
///      immune to changes in the functional fixtures. The economy, spelled out: one payer wraps
///      STRESS_SUPPLY, so total supply = 2000e18; fork threshold = supply / 20 = 100e18; the
///      createQuery bound = threshold / 2 = 50e18; the spike base = bound / 2 = 25e18; the demand
///      spike needs ~22 queries costing ~847e18 in total, plus the capped probes at 50e18 each —
///      always affordable, since the single payer holds the entire supply.
contract MultiverseQueryFeeStressTest is QueryFeeTestHelpers {
    uint256 internal constant STRESS_SUPPLY = 2000 ether;

    function setUp() public override {
        super.setUp();

        _fundWithRep(user, STRESS_SUPPLY);
    }

    /*//////////////////////////////////////////////////////////////
                    STRESS / ALGORITHM LIMITS (NO FLOOR)
    //////////////////////////////////////////////////////////////*/
    function test_QueryFee_Stress_OneWeiBaseAtNeutralCharges1Wei() public {
        // 1 wei base at the genesis-neutral point: modifier 1.0, fee = 1 wei. Passes ZeroFee and is
        // reportable (the first stake equals the 1 wei fee, above the ZeroStakeAmount guard).
        feeCtl.setFee(1);

        assertEq(_chargedFee(), 1);
    }

    function test_QueryFee_Stress_OneWeiBaseAtDeepIdleRevertsZeroFee() public {
        // Deepest down-curve point (recent = 0): a 1 wei base rounds the final fee to zero, so query
        // creation is blocked by ZeroFee while the universe idles — tiny bases DoS query creation
        // instead of minting free queries. This is the no-floor limit.
        feeCtl.setFee(1);
        _warpToWindow(1, 0); // vol[0] = 0 -> recent tail 0 -> ratio 0

        vm.prank(user);
        vm.expectRevert(Multiverse.ZeroFee.selector);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
    }

    function test_QueryFee_Stress_MinimumBaseSurvivingDeepIdle() public {
        // The smallest base whose deep-idle fee still rounds to a nonzero wei, derived from the floor
        // modifier itself: bases below it hit ZeroFee, the boundary base charges exactly 1 wei.
        _warpToWindow(1, 0);

        uint256 scale = multiverse.SCALE();
        uint256 minBase = (scale + _floorModifier() - 1) / _floorModifier(); // ceil(SCALE / floorMod)

        feeCtl.setFee(minBase - 1);
        vm.prank(user);
        vm.expectRevert(Multiverse.ZeroFee.selector);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        feeCtl.setFee(minBase);
        assertEq(_chargedFee(), 1);
    }

    function test_QueryFee_Stress_DemandSpikeSaturatesAtCap() public {
        // Inversion of the removed DemandSpikePushesLegalBaseOverForkBound revert test, after the
        // cap replaced the revert: a legal base (cap / 2) pushed over the cap by a demand spike no
        // longer blocks query creation. The first formerly-forbidden query is created charged
        // exactly the cap, and the cap stays sticky while the spike volume keeps the uncapped
        // prediction above it. High demand throttles the price at 1% of supply instead of DoS-ing
        // the universe.
        uint256 cap = zoltar.getForkThreshold(GENESIS_UID) / 2;
        uint256 base = cap / 2;
        feeCtl.setFee(base);

        uint256 volume = 0;
        while (_expectedFee(base, 0, 0, volume, 0, 0, 0) < cap) {
            _chargedFee();
            volume++;
        }

        assertEq(_chargedFee(), cap);
        assertEq(_chargedFee(), cap);
        assertEq(_chargedFee(), cap);
    }

    function test_QueryFee_Stress_DeepIdleFloorIsBaseOver101() public {
        // The lifted down-curve floors at 1/(1+100) of base: even a fully idle window prices at
        // base * floorModifier (floored), never zero, for any base at or above the minimum.
        _warpToWindow(1, 0);

        uint256 charged = _chargedFee();
        assertEq(charged, DEFAULT_FEE * _floorModifier() / multiverse.SCALE());
        // Hand-derived anchor: ratio 0 -> modifier = 1e36 / (101e18) = 9900990099009900 (floored),
        // fee = 1e18 * 9900990099009900 / 1e18 = 9900990099009900 wei (~base / 101).
        assertEq(charged, 9_900_990_099_009_900);
    }
}

/// @notice Integration suite for updateBaseFee with the real QueryFeeController wired in.
/// @dev Uses the deploy fixture's controller hooks: `_deployFeeController` returns the production
///      controller (deployed before the Multiverse) and `_afterProtocolDeploy` wires setMultiverse.
///      The monthly hill-climb is then driven through the Multiverse push path.
contract MultiverseUpdateBaseFeeTest is QueryFeeTestHelpers {
    QueryFeeController internal controller;

    function _deployFeeController() internal override returns (IQueryFeeController) {
        controller = new QueryFeeController(GENESIS_UID);
        return IQueryFeeController(address(controller));
    }

    function _afterProtocolDeploy() internal override {
        controller.setMultiverse(address(multiverse));
    }

    function setUp() public override {
        super.setUp();

        _fundWithRep(user, USER_REP_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                            UPDATE BASE FEE
    //////////////////////////////////////////////////////////////*/
    function test_UpdateBaseFee_RevertsForNonexistentUniverse() public {
        // A nonexistent universe defaults to NotExisting, which must not pass the Active gate — this
        // is what keeps junk fee states out of the controller.
        vm.warp(START_TIME + controller.THIRTY_DAYS() + 1);

        vm.expectRevert(Multiverse.InvalidUniverseState.selector);
        multiverse.updateBaseFee(uint248(999));
    }

    function test_UpdateBaseFee_RevertsInsideMonthlyWindow() public {
        // Exactly the 30-day boundary: the Active gate passes but the controller's monthly cadence
        // still rejects the push; the window opens strictly after it.
        vm.warp(START_TIME + controller.THIRTY_DAYS());

        vm.expectRevert(QueryFeeController.InvalidTimeWindow.selector);
        multiverse.updateBaseFee(GENESIS_UID);
    }

    function test_UpdateBaseFee_FirstMonthRaises() public {
        // One month in, realized profit is zero while the bootstrap fills last month's windows, so
        // profit "did not improve": the direction flips from the initial false and the fee is raised.
        uint256 initial = controller.getQueryFee(GENESIS_UID);

        vm.warp(START_TIME + controller.THIRTY_DAYS() + 1);
        multiverse.updateBaseFee(GENESIS_UID);

        assertEq(controller.getQueryFee(GENESIS_UID), initial * controller.FEE_RATE() / controller.SCALE());
    }

    function test_UpdateBaseFee_SecondMonthReversesBackExactly() public {
        // Month two: every profit window is now real (and zero), profit still hasn't improved, the
        // direction flips again and the cut is the exact inverse of the raise — back on the initial
        // base fee with zero drift.
        uint256 initial = controller.getQueryFee(GENESIS_UID);

        vm.warp(START_TIME + controller.THIRTY_DAYS() + 1);
        multiverse.updateBaseFee(GENESIS_UID);

        vm.warp(vm.getBlockTimestamp() + controller.THIRTY_DAYS() + 1);
        multiverse.updateBaseFee(GENESIS_UID);

        assertEq(controller.getQueryFee(GENESIS_UID), initial);
    }

    function test_UpdateBaseFee_NextQueryChargesFromNewBase() public {
        // After the first monthly raise, createQuery prices off the new base. Day 30 sits at the
        // start of window 10 with zero real volume: the recent tail reads the empty window 9, so the
        // down-curve floor applies to the raised base.
        vm.warp(START_TIME + controller.THIRTY_DAYS() + 1);
        multiverse.updateBaseFee(GENESIS_UID);
        uint256 newBase = controller.getQueryFee(GENESIS_UID);

        uint256 charged = _chargedFee();

        assertEq(charged, newBase * _floorModifier() / multiverse.SCALE());

        (,, uint256 storedFee,) = multiverse.queries(0);
        assertEq(storedFee, charged);
    }

    /*//////////////////////////////////////////////////////////////
                     PROFIT WIRING (RESOLVE -> HILL-CLIMB)
    //////////////////////////////////////////////////////////////*/
    function test_UpdateBaseFee_ResolvedProfitReachesTheController() public {
        // A query left unreported and resolved right after the reporting deadline pays the resolver
        // ~nothing, so ~the full fee lands as profit in the resolution window. What this pins is the
        // full pipeline: resolve records profit, _getProfits feeds it, the controller moves and
        // re-arms its clock.
        uint256 initial = controller.getQueryFee(GENESIS_UID);

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        vm.warp(START_TIME + multiverse.THREE_DAYS() + 1);
        multiverse.resolve(GENESIS_UID, 0);

        (,, uint48 timeBefore) = controller.feeStates(GENESIS_UID);

        vm.warp(START_TIME + controller.THIRTY_DAYS() + 1);
        multiverse.updateBaseFee(GENESIS_UID);

        (,, uint48 timeAfter) = controller.feeStates(GENESIS_UID);
        assertGt(timeAfter, timeBefore);
        assertNotEq(controller.getQueryFee(GENESIS_UID), initial);
    }
}
