// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { QueryFeeController } from "src/QueryFeeController.sol";

/// @notice Test harness over the fee controller: the production code plus a base fee setter and the internal
///         views the fee suites assert on. The fee fixtures deploy it in place of the controller.
contract QueryFeeControllerHarness is QueryFeeController {
    /// @param genesisBaseFee The genesis base fee to start from instead of INITIAL_BASE_FEE. Set here rather than
    ///        through `setBaseFee` so the fixture makes no call between predicting the Multiverse's address and
    ///        deploying it: in isolated test mode every call is its own transaction and moves this contract's
    ///        deployer nonce.
    constructor(uint248 genesisUniverseId, address multiverse, uint256 genesisBaseFee)
        QueryFeeController(genesisUniverseId, multiverse)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        feeStates[genesisUniverseId].baseFee = uint128(genesisBaseFee);
    }

    /// @dev Pins a universe's base fee outside the hill-climb, so a fee expectation can be stated from a known base.
    function setBaseFee(uint248 universeId, uint256 baseFee) external {
        // forge-lint: disable-next-line(unsafe-typecast)
        feeStates[universeId].baseFee = uint128(baseFee);
    }

    /// @dev The profit view as of now, as `updateBaseFee` reads it.
    function exposed_getProfits(uint248 universeId) external view returns (uint256, uint256) {
        return _getProfits(universeId, _windowOf(block.timestamp), _windowFraction(block.timestamp));
    }

    /// @dev The 3-day volume the universe is priced on now, as the fee path reads it.
    function exposed_recentVolume(uint248 universeId) external view returns (uint256) {
        mapping(uint256 windowId => ThreeDayInfo) storage windows = threeDayInfo[universeId];
        uint256 windowId = _windowOf(block.timestamp);
        return _recentVolume(windows, windowId, _windowFraction(block.timestamp), windows[windowId].threeDayVolume);
    }
}
