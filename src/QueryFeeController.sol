// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import {IQueryFeeController} from "./interfaces/IQueryFeeController.sol";

/**
 * @title QueryFeeController
 * @notice Owns the monthly base fee for each universe and adjusts it with a profit hill-climb.
 * @dev The base fee is the slow anchor of the query fee; the Multiverse multiplies it by a per-query
 *      demand modifier. Once a month the Multiverse pushes this month's and last month's realized
 *      profit into `changeBaseFee`, which nudges the base fee toward the profit-maximizing level:
 *      continue in the last direction if profit improved, reverse if it did not. The step is a fixed
 *      symmetric factor (x1.1 up, /1.1 down) so repeated oscillation carries no directional bias.
 *      This controller holds no reference to the Multiverse: profits arrive as arguments.
 */
contract QueryFeeController is IQueryFeeController {
    /* ========================================== CONSTANTS/IMMUTABLES =========================================== */
    uint256 public constant SCALE = 1 ether;
    // Fixed monthly step. Applied as *FEE_RATE/SCALE to raise and *SCALE/FEE_RATE to lower, so the two
    // directions are exact inverses (a raise then a lower returns to the original value, no down-bias).
    uint256 public constant FEE_RATE = 11 * 1e17; // 1.1
    uint256 public constant THIRTY_DAYS = 30 days;
    // Starting base fee for a freshly initialized universe, in REP.
    uint256 public constant INITIAL_BASE_FEE = 10 ether;

    /* ================================================= STRUCTS ================================================= */
    struct FeeState {
        // Current base fee for the universe, in REP.
        uint128 baseFee;
        // Direction of the last monthly change: true if it was a raise, false if a cut.
        bool baseFeeIncreased;
        // Timestamp of the last monthly change, gating the once-a-month cadence.
        uint48 timeFeeLastChanged;
    }

    /* ================================================ VARIABLES ================================================ */
    mapping(uint248 universeId => FeeState) public feeStates;

    // The Multiverse allowed to push updates. Set once by the deployer after the Multiverse is deployed.
    address public multiverse;
    address private immutable DEPLOYER;

    /* ================================================= ERRORS ================================================== */
    error OnlyMultiverse();
    error CannotSet();
    error InvalidTimeWindow();

    /* ================================================= EVENTS ================================================== */
    event BaseQueryFeeUpdated(
        uint248 indexed universeId,
        uint256 oldFee,
        uint256 newFee,
        uint48 timestamp
    );

    /* ================================================ MODIFIERS ================================================ */
    modifier onlyMultiverse() {
        if (msg.sender == multiverse) revert OnlyMultiverse();
        _;
    }
    /* ============================================ CONSTRUCTOR/SETTER =========================================== */
    constructor() {
        DEPLOYER = msg.sender;

        FeeState storage feeState = feeStates[0];
        feeState.baseFee = uint128(INITIAL_BASE_FEE);
        feeState.timeFeeLastChanged = uint48(block.timestamp);
    }

    /**
     * @notice Sets the Multiverse allowed to push updates. Callable once, by the deployer.
     * @dev Deploy order: controller first, then the Multiverse with this address, then call this.
     * @param multiverse_ The Multiverse contract address.
     */
    function setMultiverse(address multiverse_) external {
        if (msg.sender != DEPLOYER || multiverse != address(0)) revert CannotSet();

        multiverse = multiverse_;
    }

    // TODO - CHECK IF WE NEED TO ADD A FUNCTION TO INITIALIZE THE UNIVERSE FEE STATE

    /* ============================================= GETTER FUNCTION ============================================= */
    /**
     * @notice Returns the current base fee for a universe (before the per-query demand modifier).
     * @param universeId The universe to read.
     * @return The base fee in REP.
     */
    function getQueryFee(uint248 universeId) external view returns (uint256) {
        return uint256(feeStates[universeId].baseFee);
    }

    /* ============================================= CHANGE FUNCTION ============================================= */
    /**
     * @notice Adjusts a universe's base fee one monthly step, given its recent realized profits.
     * @dev Pushed by the Multiverse. Reverts until a full month has passed since the last change. Keeps
     *      the last direction if this month's profit improved on last month's, reverses it otherwise,
     *      then applies the fixed symmetric step. The caller (Multiverse) is responsible for only
     *      pushing while the universe is not forking; the once-a-month cadence is enforced here.
     * @param universeId The universe whose base fee to adjust.
     * @param currentProfit Realized profit over the last ~30 days.
     * @param lastProfit Realized profit over the ~30 days before those.
     */
    function changeBaseFee(uint248 universeId, uint256 currentProfit, uint256 lastProfit) external onlyMultiverse {
        FeeState storage feeState = feeStates[universeId];

        // Once a month only.
        if (block.timestamp - THIRTY_DAYS <= feeState.timeFeeLastChanged) revert InvalidTimeWindow();

        bool increased = feeState.baseFeeIncreased;
        // Profit did not improve -> the last move hurt -> reverse direction.
        if (currentProfit <= lastProfit) {
            increased = !increased;
        }

        // Fixed symmetric step: x1.1 to raise, /1.1 to lower.
        uint256 oldFee = uint256(feeState.baseFee);
        uint256 newFee = increased ? oldFee * FEE_RATE / SCALE : oldFee * SCALE / FEE_RATE;
        feeState.baseFee = uint128(newFee);
        feeState.baseFeeIncreased = increased;
        feeState.timeFeeLastChanged = uint48(block.timestamp);

        emit BaseQueryFeeUpdated(universeId, oldFee, newFee, uint48(block.timestamp));
    }
}
