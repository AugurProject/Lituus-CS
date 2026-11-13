// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IQueryFeeController } from "./interfaces/IQueryFeeController.sol";

/**
 * @title QueryFeeController
 * @notice Prices the Multiverse's queries. Holds every universe's monthly base fee, the demand history the
 *         per-query modifier is read from, and the realized profits the base fee's monthly hill-climb is
 *         steered by. The Multiverse computes no fee itself: it asks for one and reports what happened.
 * @dev The base fee is the slow anchor of the query fee. Once a month `updateBaseFee` nudges it toward the
 *      profit-maximizing level: continue in the last direction if profit improved, reverse if it did not. The
 *      step is a fixed symmetric factor (x1.1 up, /1.1 down) so repeated oscillation carries no directional
 *      bias. On top of it `chargeQuery` applies a demand modifier, the last 3 days of volume against the 60-day
 *      average. Volume and profit are bucketed into 3-day windows counted from GENESIS_TIMESTAMP and shared by
 *      every universe; a child universe is seeded from its parent's buckets at spawn.
 *      Every mutating entry is Multiverse-only. The controller never calls the Multiverse back.
 */
contract QueryFeeController is IQueryFeeController {
    /* ========================================== CONSTANTS/IMMUTABLES =========================================== */
    uint256 public constant SCALE = 1 ether;
    // Fixed monthly step. Applied as *FEE_RATE/SCALE to raise and *SCALE/FEE_RATE to lower, so the two
    // directions are exact inverses (a raise then a lower returns to the original value, no down-bias).
    uint256 public constant FEE_RATE = 11 * 1e17; // 1.1
    uint256 public constant THIRTY_DAYS = 30 days;
    uint256 public constant THREE_DAYS = 3 days;
    // Starting base fee for a freshly initialized universe, in REP.
    uint256 public constant INITIAL_BASE_FEE = 10 ether;
    // The volume for a three day window that needs to get booted in (when we need to calculate pre genesis).
    uint256 public constant BOOT_VOLUME = 3;
    // The profit for a three day window that needs to get booted in (when we need to calculate pre genesis).
    uint256 public constant BOOT_PROFIT = 2 * INITIAL_BASE_FEE;
    // The anchor of the 3-day windows, shared by every universe: deploy time.
    uint256 public immutable GENESIS_TIMESTAMP;
    // The Multiverse this controller prices for, the only caller of its mutating entries. Bound at construction
    // to the address the Multiverse is about to be deployed to (see Deploy.s.sol).
    address public immutable MULTIVERSE;

    /* ================================================= STRUCTS ================================================= */
    // One slot.
    struct FeeState {
        // Current base fee for the universe, in REP.
        uint128 baseFee;
        // Direction of the last monthly change: true if it was a raise, false if a cut.
        bool baseFeeIncreased;
        // Timestamp of the last monthly change, gating the once-a-month cadence.
        uint48 timeFeeLastChanged;
        // The 3-day window the last query was recorded in, which the 60-day cache is anchored at.
        uint32 lastWindowId;
        // Query count over the 20 windows before `lastWindowId`, kept per query instead of doing 20 SLOADs.
        uint40 sixtyDayVolume;
    }

    // Real values only, with one exception: the windows a child inherits for the frozen gap between its parent's
    // fork trigger and its own spawn are filled at the parent's rates (see seedChild).
    struct ThreeDayInfo {
        // The realized profit of the universe in this window, in REP.
        uint128 threeDayProfit;
        // The number of queries created in the universe in this window.
        uint128 threeDayVolume;
    }

    /* ================================================ VARIABLES ================================================ */
    mapping(uint248 universeId => FeeState) public feeStates;
    mapping(uint248 universeId => mapping(uint256 windowId => ThreeDayInfo)) public threeDayInfo;

    /* ================================================= ERRORS ================================================== */
    error OnlyMultiverse();
    error CannotSet();
    error ZeroAddress();
    error InvalidTimeWindow();

    /* ================================================= EVENTS ================================================== */
    event BaseQueryFeeUpdated(uint248 indexed universeId, uint256 oldFee, uint256 newFee, uint48 timestamp);

    /* ================================================ MODIFIERS ================================================ */
    // the check is a single guard; keeping it inline for better readability
    // forge-lint: disable-next-item(unwrapped-modifier-logic)
    modifier onlyMultiverse() {
        if (msg.sender != MULTIVERSE) revert OnlyMultiverse();
        _;
    }

    /* =============================================== CONSTRUCTOR =============================================== */
    /**
     * @notice Seeds the genesis universe's fee state and anchors the 3-day windows at deploy time.
     * @param genesisUniverseId The genesis universe id — the Zoltar universe id the Multiverse is
     * deployed with, since Lituus universe ids mirror Zoltar universe ids.
     * @param multiverse The Multiverse this controller serves, at the address it is about to be deployed to.
     */
    constructor(uint248 genesisUniverseId, address multiverse) {
        if (multiverse == address(0)) revert ZeroAddress();
        MULTIVERSE = multiverse;
        GENESIS_TIMESTAMP = block.timestamp;

        FeeState storage feeState = feeStates[genesisUniverseId];
        // INITIAL_BASE_FEE is within REP total supply, within uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        feeState.baseFee = uint128(INITIAL_BASE_FEE);
        feeState.timeFeeLastChanged = uint48(block.timestamp);
    }

    /* ========================================== MULTIVERSE ENTRY POINTS ======================================== */
    /**
     * @inheritdoc IQueryFeeController
     * @dev Demand is a live rolling 3-day window rebuilt from discrete buckets, so the fee neither ramps
     *      within a window nor goes stale. `w` is the current window, `vol[x]` a real stored bucket, and
     *      `f` the fraction of `w` elapsed. Bootstrap volume for pre-genesis windows is NEVER stored; it
     *      is added only to the local values below, so storage holds real volume only (the one exception
     *      being a child's rate-filled fork gap, see seedChild).
     *
     *        lastThreeDayVolume = vol[w] + (1 - f) * prevWindowVolume
     *        lastSixtyDayVolume = vol[w] + sixtyDayVolume - f * oldestWindowVolume        (w >= 20)
     *                           = vol[w] + sixtyDayVolume + (20 - w) * BOOT_VOLUME         (w  < 20)
     *
     *      where `prevWindowVolume` / `oldestWindowVolume` fall back to BOOT_VOLUME when window `w-1` /
     *      `w-20` predates genesis. `sixtyDayVolume` is the running sum of the real windows `vol[w-1..w-20]`,
     *      rolled forward once per new window (completed real window in, real window now older than 60 days
     *      out; a gap >= 20 recomputes it from real storage). The query is counted only AFTER its fee is
     *      computed, so it never prices itself.
     */
    function chargeQuery(uint248 universeId) external onlyMultiverse returns (uint256 fee) {
        FeeState memory state = feeStates[universeId];
        uint256 windowId = _windowOf(block.timestamp);
        // Advance the incremental 60-day cache to the current window before reading it below.
        if (_rollCache(universeId, state, windowId)) feeStates[universeId] = state;

        uint256 currentVolume;
        (fee, currentVolume) = _quote(universeId, state, windowId, _windowFraction(block.timestamp));

        // count this query in the current demand-volume bucket for future fees. Nothing has written the
        // bucket since `currentVolume` was read, so reuse it instead of re-reading.
        // a per-window query count, far below the uint128 max
        // forge-lint: disable-next-line(unsafe-typecast)
        threeDayInfo[universeId][windowId].threeDayVolume = uint128(currentVolume + 1);
    }

    /**
     * @inheritdoc IQueryFeeController
     * @dev The lightweight half of `chargeQuery`. Rolls the cache first (like the organic path) so a
     *      token-only stretch — redemptions recording volume with no organic query in between — never lets
     *      the cache go stale.
     */
    function recordQuery(uint248 universeId) external onlyMultiverse {
        FeeState memory state = feeStates[universeId];
        uint256 windowId = _windowOf(block.timestamp);
        if (_rollCache(universeId, state, windowId)) feeStates[universeId] = state;

        threeDayInfo[universeId][windowId].threeDayVolume += 1;
    }

    /**
     * @inheritdoc IQueryFeeController
     * @dev The bucket is keyed by the 3-day window index derived from the global genesis anchor
     *      (`(block.timestamp - GENESIS_TIMESTAMP) / THREE_DAYS`). The sparse mapping avoids any
     *      age-dependent array padding and lets a fork copy a fixed window of buckets regardless of
     *      universe age. Only the windowed profit bucket is updated; `_getProfits` reconstructs the
     *      rolling monthly totals from the buckets on demand.
     */
    function recordProfit(uint248 universeId, uint256 profit) external onlyMultiverse {
        // profit is a REP amount bounded by max supply (100M * 1e18), within uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        threeDayInfo[universeId][_windowOf(block.timestamp)].threeDayProfit += uint128(profit);
    }

    /**
     * @inheritdoc IQueryFeeController
     * @dev The base fee is inherited as it stands (a zero base fee would be stuck at zero forever, since the
     *      monthly step is multiplicative), along with the direction of the parent's last monthly move, so the
     *      child's first hill-climb step judges that move against the inherited profits rather than a cut it
     *      never made. The monthly-change timestamp restarts, so that first step waits a full month.
     *      The history is calendar-anchored: for the 21 windows ending at the spawn window, bucket w of the child
     *      is bucket w of the parent, so the child quotes what the parent would quote now, and a spawn in the
     *      trigger's own block is a plain copy. The parent is frozen since the fork trigger, so the time between
     *      the trigger and the spawn holds nothing; left empty it would open the child at the down-curve floor
     *      (an empty recent window) and hand its first hill-climb an empty baseline month. That time is
     *      filled from the parent's per-window values as of the trigger instead: for volume the count of the
     *      window before the trigger window, for profit a tenth of the 30-day profit its hill-climb read. The
     *      fill covers the frozen part of the trigger window (to the spawn, or to the window's end), every
     *      whole frozen window, and the elapsed share of a later spawn window. The volume fill is the last
     *      complete window: a finished count that neither the trigger moment nor the trigger window's own
     *      queries can move, so the forker's choice of when to trigger cannot push a child's opening fee down.
     *      Completing the trigger window from it is also what the fee path was already extrapolating (it reads
     *      a window as its count plus the unelapsed share of the previous window's), so a child spawned inside
     *      the trigger window is priced as the parent was; from the second window after the trigger a child is
     *      priced on the previous window's count, whatever the spawn moment. The profit fill has no invariant
     *      of that kind (the 30-day sum necessarily drifts as the fill replaces windows rolling out of it).
     *      These are the only stored bucket values that are not real counts; nothing but the fee curve and
     *      the hill-climb reads them.
     *      The cache is the sum of the 20 windows before the spawn window, exactly as the roll would produce
     *      it from the child's buckets. The anchor is the CURRENT window, not the parent's `lastWindowId`:
     *      that only moves on query creation, so a resolve between the parent's last query and the trigger
     *      books profit into a window above it, which an anchor on `lastWindowId` would miss.
     *      One storage write per non-empty window of the 21 copied, plus the child's fee state.
     */
    function seedChild(uint248 parentId, uint248 childId, uint256 forkTime) external onlyMultiverse {
        if (feeStates[childId].timeFeeLastChanged != 0) revert CannotSet();
        mapping(uint256 windowId => ThreeDayInfo) storage parentWindows = threeDayInfo[parentId];
        mapping(uint256 windowId => ThreeDayInfo) storage childWindows = threeDayInfo[childId];
        uint256 spawnWindow = _windowOf(block.timestamp);
        uint256 triggerWindow = _windowOf(forkTime);
        uint256 spawnFraction = _windowFraction(block.timestamp);
        uint256 triggerFraction = _windowFraction(forkTime);
        uint256 volumePerWindow;
        uint256 profitPerWindow;
        // Any frozen time between the trigger and the spawn is filled from the parent's per-window volume and
        // profit as of the trigger.
        if (block.timestamp > forkTime) {
            (volumePerWindow, profitPerWindow) = _fillPerWindowAt(parentId, triggerWindow, triggerFraction);
        }

        uint256 sixtyDayVolume;
        for (uint256 i = 0; i <= 20;) {
            if (spawnWindow >= i) {
                uint256 windowId = spawnWindow - i;
                ThreeDayInfo memory info;
                // The parent holds real values up to the trigger window and nothing after it (not read).
                if (windowId <= triggerWindow) info = parentWindows[windowId];
                // From the trigger window on, the window's frozen span is filled: it starts at the trigger in
                // the trigger window (at the window start after it) and ends at the spawn in the spawn window
                // (at the window end before it). Empty for a spawn in the trigger's own block.
                if (windowId >= triggerWindow) {
                    uint256 frozenEnd = windowId == spawnWindow ? spawnFraction : SCALE;
                    uint256 frozenStart = windowId == triggerWindow ? triggerFraction : 0;
                    uint256 frozen = frozenEnd - frozenStart;
                    // a per-window query count, far below the uint128 max
                    // forge-lint: disable-next-line(unsafe-typecast)
                    info.threeDayVolume += uint128(volumePerWindow * frozen / SCALE);
                    // a REP amount bounded by max supply, within uint128
                    // forge-lint: disable-next-line(unsafe-typecast)
                    info.threeDayProfit += uint128(profitPerWindow * frozen / SCALE);
                }
                if (info.threeDayVolume != 0 || info.threeDayProfit != 0) childWindows[windowId] = info;
                if (i >= 1) sixtyDayVolume += info.threeDayVolume;
            }
            unchecked {
                i += 1;
            }
        }

        FeeState storage parent = feeStates[parentId];
        feeStates[childId] = FeeState({
            baseFee: parent.baseFee,
            baseFeeIncreased: parent.baseFeeIncreased,
            timeFeeLastChanged: uint48(block.timestamp),
            // 3-day window index since genesis, far below the uint32 max
            // forge-lint: disable-next-line(unsafe-typecast)
            lastWindowId: uint32(spawnWindow),
            // running query count over the window range, far below the uint40 max
            // forge-lint: disable-next-line(unsafe-typecast)
            sixtyDayVolume: uint40(sixtyDayVolume)
        });
    }

    /**
     * @inheritdoc IQueryFeeController
     * @dev Reverts until a full month has passed since the last change. Keeps the last direction if this
     *      month's profit improved on last month's, reverses it otherwise, then applies the fixed symmetric
     *      step. The Multiverse is responsible for only calling while the universe is not forking; the
     *      once-a-month cadence is enforced here.
     */
    function updateBaseFee(uint248 universeId) external onlyMultiverse {
        FeeState memory state = feeStates[universeId];
        // Once a month only.
        if (block.timestamp - THIRTY_DAYS <= state.timeFeeLastChanged) revert InvalidTimeWindow();

        (uint256 currentProfit, uint256 lastProfit) =
            _getProfits(universeId, _windowOf(block.timestamp), _windowFraction(block.timestamp));

        bool increased = state.baseFeeIncreased;
        // Profit did not improve -> the last move hurt -> reverse direction.
        if (currentProfit <= lastProfit) {
            increased = !increased;
        }

        // Fixed symmetric step: x1.1 to raise, /1.1 to lower.
        uint256 oldFee = uint256(state.baseFee);
        uint256 newFee = increased ? oldFee * FEE_RATE / SCALE : oldFee * SCALE / FEE_RATE;
        // newFee is in REP tokens, staying within uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        state.baseFee = uint128(newFee);
        state.baseFeeIncreased = increased;
        state.timeFeeLastChanged = uint48(block.timestamp);
        feeStates[universeId] = state;

        emit BaseQueryFeeUpdated(universeId, oldFee, newFee, uint48(block.timestamp));
    }

    /* ============================================== VIEW FUNCTIONS ============================================= */
    /**
     * @inheritdoc IQueryFeeController
     * @dev Read-only twin of `chargeQuery`'s fee computation, WITHOUT rolling the volume cache forward or
     *      recording a query. A `view` cannot persist the incremental `sixtyDayVolume` cache, so it advances
     *      a copy in memory. When the cache is fresh — which every recorded query, redemptions included, keeps
     *      it — this is a single cached read with no loop; only a genuinely idle span (no query at all since
     *      `lastWindowId`) pays the catch-up, exactly as the mutating path would.
     */
    function previewFee(uint248 universeId) external view returns (uint256 fee) {
        FeeState memory state = feeStates[universeId];
        uint256 windowId = _windowOf(block.timestamp);
        _rollCache(universeId, state, windowId);

        (fee,) = _quote(universeId, state, windowId, _windowFraction(block.timestamp));
    }

    /**
     * @notice Returns the current base fee for a universe (before the per-query demand modifier).
     * @param universeId The universe to read.
     * @return The base fee in REP.
     */
    function getQueryFee(uint248 universeId) external view returns (uint256) {
        return uint256(feeStates[universeId].baseFee);
    }

    /* ============================================ QUERY FEE INTERNALS ========================================== */
    /**
     * @notice `baseFee × demandModifier` for a universe, from the current window's stored volume and a
     *         60-day cache already rolled to that window.
     * @dev Shared by `chargeQuery` and `previewFee`, so the local-volume math lives in exactly one place.
     *      Bootstrap stays local only. In both branches the oldest window (real for w >= 20, bootstrap for
     *      w < 20) contributes only its (1 - f) tail, since f of it has already slid out of the 60-day span.
     * @param universeId The universe to price.
     * @param state The universe's fee state, with the cache rolled to `windowId`.
     * @param windowId The current window.
     * @param fraction The fraction of `windowId` elapsed, SCALE-scaled, in [0, SCALE).
     * @return fee The uncapped query fee.
     * @return currentVolume The stored volume of `windowId`, so a mutating caller can bump it without re-reading.
     */
    function _quote(uint248 universeId, FeeState memory state, uint256 windowId, uint256 fraction)
        internal
        view
        returns (uint256 fee, uint256 currentVolume)
    {
        mapping(uint256 windowId => ThreeDayInfo) storage windows = threeDayInfo[universeId];
        currentVolume = windows[windowId].threeDayVolume;

        // recent 3-day (local): current partial + tail of the previous window
        uint256 lastThreeDayVolume = _recentVolume(windows, windowId, fraction, currentVolume);

        // 60-day (local): current + real running sum, then trim the oldest window's rolled-out tail.
        uint256 lastSixtyDayVolume = currentVolume + state.sixtyDayVolume;
        if (windowId >= 20) {
            // oldest window (w-20) is real: subtract the f-tail that rolled out
            uint256 oldestVolume = windows[windowId - 20].threeDayVolume;
            lastSixtyDayVolume -= fraction * oldestVolume / SCALE;
        } else {
            // missing pre-genesis windows are bootstrap. The (20 - w - 1) newer ones enter whole; the single
            // oldest (w-20) enters only its (1 - f) tail — same trimming the real branch applies
            lastSixtyDayVolume += (20 - windowId - 1) * BOOT_VOLUME + (SCALE - fraction) * BOOT_VOLUME / SCALE;
        }

        uint256 baseFee = state.baseFee;
        fee = baseFee * _calculateCurveModifier(lastSixtyDayVolume, lastThreeDayVolume) / SCALE;
    }

    /**
     * @notice Advances the incremental 60-day volume cache (`sixtyDayVolume` + `lastWindowId`) of an
     *         in-memory fee state to the current window.
     * @dev The single roll, shared by every query-recording path (organic and tokenizer) and by the preview,
     *      so the cache stays fresh no matter which path last recorded volume. A no-op when the current
     *      window already equals `lastWindowId` — at most one real roll happens per universe per window.
     *      Works on the caller's memory copy: a mutating caller writes it back when this returns true, a view
     *      caller just reads the advanced copy.
     * @param universeId The universe the state belongs to.
     * @param state The universe's fee state, advanced in place.
     * @param windowId The current 3-day window index.
     * @return Whether the cache moved.
     */
    function _rollCache(uint248 universeId, FeeState memory state, uint256 windowId) internal view returns (bool) {
        uint256 lastWindow = state.lastWindowId;
        if (windowId <= lastWindow) return false;

        uint256 sixtyDayVolume =
            _rolledSixtyDayVolume(threeDayInfo[universeId], windowId, lastWindow, state.sixtyDayVolume);
        // running query count over the window range, far below the uint40 max
        // forge-lint: disable-next-line(unsafe-typecast)
        state.sixtyDayVolume = uint40(sixtyDayVolume);
        // 3-day window index since genesis, far below the uint32 max
        // forge-lint: disable-next-line(unsafe-typecast)
        state.lastWindowId = uint32(windowId);
        return true;
    }

    /**
     * @notice Rolls a cached 60-day volume from `lastWindow` up to `currentWindow`, read-only.
     * @dev Storage holds no bootstrap volume (only real counts, plus a child's rate-filled fork gap, see
     *      seedChild), so nothing bootstrap-related is added or subtracted here.
     * @param windows The universe's 3-day buckets.
     * @param currentWindow The window to roll the cache up to.
     * @param lastWindow The window the cache is currently anchored at.
     * @param cachedSixtyDayVolume The cached sum as of `lastWindow`.
     * @return sixtyDayVolume The 60-day running sum as of `currentWindow`.
     */
    function _rolledSixtyDayVolume(
        mapping(uint256 windowId => ThreeDayInfo) storage windows,
        uint256 currentWindow,
        uint256 lastWindow,
        uint256 cachedSixtyDayVolume
    ) internal view returns (uint256 sixtyDayVolume) {
        sixtyDayVolume = cachedSixtyDayVolume;
        if (currentWindow <= lastWindow) return sixtyDayVolume;

        if (currentWindow - lastWindow >= 20) {
            // Idle >= 60 days: every real window in range rolled out; recompute from real storage only.
            uint256 sum;
            for (uint256 i = 1; i <= 20;) {
                // real window only; a window c-i predating genesis contributes 0 (bootstrap is not stored)
                if (currentWindow >= i) {
                    sum += windows[currentWindow - i].threeDayVolume;
                }
                unchecked {
                    i += 1;
                }
            }
            sixtyDayVolume = sum;
        } else {
            for (uint256 i = lastWindow; i < currentWindow;) {
                sixtyDayVolume += windows[i].threeDayVolume; // completed real window enters
                if (i >= 20) {
                    // Real window leaves; bootstrap never subtracted (no accounting for bootstrap).
                    sixtyDayVolume -= windows[i - 20].threeDayVolume;
                }
                unchecked {
                    i += 1;
                }
            }
        }
    }

    /**
     * @notice Turns the demand ratio (recent 3-day volume vs the 60-day average) into the multiplier
     *         applied to the base fee.
     * @dev Ratio is SCALE-scaled: SCALE (1.0) means the recent rate equals the 60-day average. An empty
     *      60-day window (only possible with zero history) yields a neutral 1.0, so a brand-new or idle
     *      universe is not pushed to the bottom of the curve.
     *
     *      Above average (ratio >= SCALE): a gentle linear rise, 0.8 + 0.2 * ratio, so double the demand
     *      is only +20%. Since recent3 <= sixty always, ratio is bounded by 20 and this branch by 4.8x.
     *
     *      Below average (ratio < SCALE): a steep drop, 1 / (1 + 100 * (1 - ratio)^6). The 6th power is
     *      built iteratively (each step re-divided by SCALE) because (1 - ratio)^6 in SCALE fixed-point
     *      would overflow a direct exponentiation.
     *
     *      TODO: the below-average branch bottoms out near ~1% of the base fee; since the fee is also
     *      TODO: the first report's bond, a floor may be needed (needs testing).
     * @param lastSixtyDayVolume The reconstructed 60-day rolling volume (denominator).
     * @param lastThreeDayVolume The reconstructed 3-day rolling volume (numerator).
     * @return modifier_ The SCALE-scaled multiplier to apply to the base fee.
     */
    function _calculateCurveModifier(uint256 lastSixtyDayVolume, uint256 lastThreeDayVolume)
        internal
        pure
        returns (uint256 modifier_)
    {
        uint256 ratio = lastSixtyDayVolume == 0 ? SCALE : 20 * lastThreeDayVolume * SCALE / lastSixtyDayVolume;

        if (ratio >= SCALE) {
            // above average: gentle linear rise, slope 0.2
            modifier_ = (4 * SCALE) / 5 + ratio / 5;
        } else {
            // Below average: steep drop.
            uint256 shortage = SCALE - ratio;
            uint256 powered = SCALE;
            for (uint256 i = 0; i < 6;) {
                powered = powered * shortage / SCALE;
                unchecked {
                    i += 1;
                }
            }
            modifier_ = SCALE * SCALE / (SCALE + 100 * powered);
        }
    }

    /**
     * @notice The 3-day volume a universe is priced on at a moment: the moment's window so far plus the
     *         unelapsed tail of the previous window.
     * @dev The one definition behind the fee path and its preview.
     * @param windows The universe's 3-day buckets.
     * @param windowId The window of the moment.
     * @param fraction The fraction of that window elapsed, SCALE-scaled, in [0, SCALE).
     * @param currentVolume The volume of `windowId`, already read by the caller.
     * @return currentVolume + (1 - fraction) * previousWindowVolume, floored.
     */
    function _recentVolume(
        mapping(uint256 windowId => ThreeDayInfo) storage windows,
        uint256 windowId,
        uint256 fraction,
        uint256 currentVolume
    ) internal view returns (uint256) {
        return currentVolume + (SCALE - fraction) * _previousWindowVolume(windows, windowId) / SCALE;
    }

    /// @dev The count of the window before `windowId`: real volume, or bootstrap if it predates genesis
    ///      (checked before the read).
    function _previousWindowVolume(mapping(uint256 windowId => ThreeDayInfo) storage windows, uint256 windowId)
        internal
        view
        returns (uint256)
    {
        return windowId >= 1 ? windows[windowId - 1].threeDayVolume : BOOT_VOLUME;
    }

    /* ============================================== PROFIT INTERNALS =========================================== */
    /**
     * @notice Realized profit of the ~30-day period ending at a given moment and of the ~30 days before it, as
     *         live rolling windows, for the monthly base-fee hill-climb.
     * @dev With `c` the moment's window and `f` the fraction of it
     *      elapsed, `currentProfit` is the 30 days ending at the moment and `lastProfit` the 30 days before:
     *        currentProfit = profit[c] + sum(profit[c-1..c-9]) + (1 - f) * profit[c-10]
     *        lastProfit    = f * profit[c-10] + sum(profit[c-11..c-19]) + (1 - f) * profit[c-20]
     *      The boundary window c-10 is split between the two periods; the oldest window c-20 contributes
     *      only its (1 - f) tail. Windows predating genesis fall back to BOOT_PROFIT (checked before each
     *      read). Profit only — no division here, so a zero period is harmless to the hill-climb. The moment
     *      is a parameter (callers pass now, or the fork trigger for the fork-gap fill's profit rate).
     * @param universeId The universe to read.
     * @param currentThreeDayWindow The window of the moment.
     * @param proportionOfCurrentWindow The fraction of that window elapsed, SCALE-scaled, in [0, SCALE).
     * @return currentProfit Rolling realized profit over the 30 days ending at the moment.
     * @return lastProfit Rolling realized profit over the 30 days before those.
     */
    function _getProfits(uint248 universeId, uint256 currentThreeDayWindow, uint256 proportionOfCurrentWindow)
        internal
        view
        returns (uint256 currentProfit, uint256 lastProfit)
    {
        mapping(uint256 windowId => ThreeDayInfo) storage windows = threeDayInfo[universeId];

        // Current month: current window's partial profit + the 9 completed windows behind it.
        currentProfit = windows[currentThreeDayWindow].threeDayProfit;
        for (uint256 i = 1; i <= 9;) {
            currentProfit += currentThreeDayWindow >= i
                ? windows[currentThreeDayWindow - i].threeDayProfit
                : BOOT_PROFIT;
            unchecked {
                i += 1;
            }
        }

        // Boundary window c-10 is split: (1 - f) tail to the current month, f to the previous month.
        uint256 boundaryProfit =
            currentThreeDayWindow >= 10 ? windows[currentThreeDayWindow - 10].threeDayProfit : BOOT_PROFIT;
        currentProfit += (SCALE - proportionOfCurrentWindow) * boundaryProfit / SCALE;
        lastProfit += proportionOfCurrentWindow * boundaryProfit / SCALE;

        // Previous month: the 9 completed windows behind the boundary.
        for (uint256 i = 11; i <= 19;) {
            lastProfit += currentThreeDayWindow >= i ? windows[currentThreeDayWindow - i].threeDayProfit : BOOT_PROFIT;
            unchecked {
                i += 1;
            }
        }

        // oldest window c-20 contributes only its (1 - f) tail; the rest has rolled out of the 60-day span
        uint256 oldestProfit =
            currentThreeDayWindow >= 20 ? windows[currentThreeDayWindow - 20].threeDayProfit : BOOT_PROFIT;
        lastProfit += (SCALE - proportionOfCurrentWindow) * oldestProfit / SCALE;
    }

    /**
     * @notice The per-window values a child's fork gap is filled with, as of a past moment of the parent.
     * @dev The volume is the count of the window before the moment's (bootstrap if it predates genesis): the
     *      last complete window. The profit is a tenth of the 30-day realized profit the hill-climb reads at
     *      the moment.
     * @param universeId The universe to read.
     * @param windowId The window of the moment.
     * @param fraction The fraction of that window elapsed at the moment, SCALE-scaled.
     * @return volumePerWindow Queries per whole frozen window.
     * @return profitPerWindow Realized profit per whole frozen window.
     */
    function _fillPerWindowAt(uint248 universeId, uint256 windowId, uint256 fraction)
        internal
        view
        returns (uint256 volumePerWindow, uint256 profitPerWindow)
    {
        volumePerWindow = _previousWindowVolume(threeDayInfo[universeId], windowId);
        (uint256 currentProfit,) = _getProfits(universeId, windowId, fraction);
        profitPerWindow = currentProfit / 10; // currentProfit is for 30 days, a window is 3
    }

    /* ============================================== WINDOW INTERNALS =========================================== */
    /**
     * @notice The 3-day window `timestamp` falls in, counted from genesis.
     * @param timestamp A moment at or after genesis.
     */
    function _windowOf(uint256 timestamp) internal view returns (uint256) {
        return (timestamp - GENESIS_TIMESTAMP) / THREE_DAYS;
    }

    /**
     * @notice The fraction of its 3-day window that `timestamp` has elapsed, SCALE-scaled, in [0, SCALE).
     * @param timestamp A moment at or after genesis.
     */
    function _windowFraction(uint256 timestamp) internal view returns (uint256) {
        return ((timestamp - GENESIS_TIMESTAMP) % THREE_DAYS) * SCALE / THREE_DAYS;
    }
}
