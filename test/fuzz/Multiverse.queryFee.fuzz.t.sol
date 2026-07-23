// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { QueryFeeTestHelpers } from "../unit/Multiverse.queryFee.t.sol";

/// @notice Random-schedule fuzz for the demand modifier: a random timeline of warps and query
///         bursts must price every single query exactly as the independent mirror predicts.
/// @dev Generalizes the unit suite's hand-picked points (neutral, floor, cliff, handoff) to
///      arbitrary interleavings: random window gaps (including gaps of 20+ windows, exercising
///      the recompute branch), random in-window fractions, and random burst sizes. The test
///      tracks ghost volume state with its own reimplementation of the rollover and checks each
///      charge against the pricing mirror for that state: a divergence between the code and the
///      mirror anywhere in the schedule space fails the run. The base fee stays at DEFAULT_FEE,
///      so the maximum possible charge (4.8x) is far below the fee cap and above the ZeroFee
///      floor - neither bound can trigger and the uncapped mirror is valid everywhere.
contract MultiverseQueryFeeFuzzTest is QueryFeeTestHelpers {
    uint256 internal constant STEPS = 10;
    // Gaps can exceed 20 windows so the rollover's full-recompute branch is exercised too.
    uint256 internal constant MAX_GAP_WINDOWS = 25;

    // Ghost mirror of the contract's volume state.
    mapping(uint256 => uint256) internal ghostVolume;
    uint256 internal ghostLastWindow;
    uint256 internal ghostSixty;

    function setUp() public override {
        super.setUp();

        _fundWithRep(user, USER_REP_BALANCE);
    }

    /// @dev Property: for every query in a random schedule, the charged fee equals the mirror's
    /// prediction for the ghost state at charge time.
    function testFuzz_QueryFee_ChargedAlwaysMatchesMirror(uint256 seed) public {
        uint256 threeDays = multiverse.THREE_DAYS();
        uint256 scale = multiverse.SCALE();

        for (uint256 step = 0; step < STEPS; step++) {
            uint256 delta = uint256(keccak256(abi.encode(seed, step, "warp"))) % (MAX_GAP_WINDOWS * threeDays + 1);
            vm.warp(block.timestamp + delta);

            uint256 burst = uint256(keccak256(abi.encode(seed, step, "burst"))) % 4;
            for (uint256 q = 0; q < burst; q++) {
                uint256 windowId = (block.timestamp - START_TIME) / threeDays;
                uint256 fractionElapsed = (block.timestamp - START_TIME) % threeDays * scale / threeDays;

                _rollGhostForward(windowId);

                uint256 expected = _expectedFee(
                    DEFAULT_FEE,
                    windowId,
                    fractionElapsed,
                    ghostVolume[windowId],
                    windowId >= 1 ? ghostVolume[windowId - 1] : 0,
                    ghostSixty,
                    windowId >= 20 ? ghostVolume[windowId - 20] : 0
                );

                assertEq(_chargedFee(), expected);

                // Count-after-fee, mirrored: the query enters its bucket only after being priced.
                ghostVolume[windowId] += 1;
            }
        }
    }

    /// @dev Ghost reimplementation of the rollover: step accumulation for short gaps (completed
    /// window enters, the window 20 behind it leaves), full recompute over the last 20 windows
    /// for gaps of 20 windows or more.
    function _rollGhostForward(uint256 windowId) internal {
        if (windowId <= ghostLastWindow) return;

        if (windowId - ghostLastWindow >= 20) {
            uint256 sum;
            for (uint256 i = 1; i <= 20; i++) {
                if (windowId >= i) {
                    sum += ghostVolume[windowId - i];
                }
            }
            ghostSixty = sum;
        } else {
            for (uint256 i = ghostLastWindow; i < windowId; i++) {
                ghostSixty += ghostVolume[i];
                if (i >= 20) {
                    ghostSixty -= ghostVolume[i - 20];
                }
            }
        }
        ghostLastWindow = windowId;
    }
}
