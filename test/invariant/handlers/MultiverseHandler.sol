// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { CommonBase } from "forge-std/Base.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { MockQueryFeeController } from "src/mock/MockQueryFeeController.sol";

/// @notice Handler for stateful fuzzing of createQuery. Wraps calls with bounded inputs.
/// @dev    The invariant runner picks random functions from this contract. The handler holds
///         REP and is the query creator; ghost variables track the expected on-chain state.
contract MultiverseHandler is CommonBase, StdCheats, StdUtils {
    // Per-call fee ceiling, small relative to the handler's REP balance so cumulative fees
    // over an entire run never exhaust it.
    uint256 internal constant MAX_FEE = 1e24;

    Multiverse public immutable MULTIVERSE;
    MockQueryFeeController public immutable FEE_CTL;
    ILituusRep public immutable REP;
    uint248 public immutable GENESIS_UID;

    // Ghost variables, observable from invariants.
    uint256 public ghostQueriesCreated;
    uint256 public ghostTotalFees;

    constructor(Multiverse multiverse_, MockQueryFeeController feeCtl_, ILituusRep rep_, uint248 genesisUid_) {
        MULTIVERSE = multiverse_;
        FEE_CTL = feeCtl_;
        REP = rep_;
        GENESIS_UID = genesisUid_;
    }

    /// @notice Create a query with a valid, bounded outcome count and fee.
    function createQuery(uint256 outcomeSeed, uint256 feeSeed) external {
        uint8 outcomes = uint8(bound(outcomeSeed, MULTIVERSE.MIN_OUTCOMES(), MULTIVERSE.MAX_OUTCOMES()));
        uint256 fee = bound(feeSeed, 0, MAX_FEE);

        FEE_CTL.setFee(fee);
        uint256 balanceBefore = REP.balanceOf(address(this));
        MULTIVERSE.createQuery(GENESIS_UID, "q", outcomes);

        ++ghostQueriesCreated;
        ghostTotalFees += balanceBefore - REP.balanceOf(address(this));
    }
}
