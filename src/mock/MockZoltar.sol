// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IZoltar, IZoltarQuestionData } from "../interfaces/IZoltar.sol";
import { IReputationToken } from "../interfaces/IReputationToken.sol";

contract MockZoltar is IZoltar {
    uint256 constant FORK_THRESHOLD_DIVISOR = 20; // 5% of total supply atm

    // mock accessors mirror the interface's lowercase getter names, so keep the non-standard casing
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IReputationToken public immutable repToken;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IZoltarQuestionData public immutable zoltarQuestionData;

    constructor(IReputationToken repToken_, IZoltarQuestionData zoltarQuestionData_) {
        repToken = repToken_;
        zoltarQuestionData = zoltarQuestionData_;
    }

    function getChildUniverseId(uint248 universeId, uint256) external pure returns (uint248) {
        return universeId;
    }

    function getRepToken(uint248) external view returns (IReputationToken) {
        return repToken;
    }

    function getUniverseTheoreticalSupply(uint248) public view returns (uint256) {
        return repToken.totalSupply();
    }

    function getForkThreshold(uint248 universeId) public view returns (uint256) {
        return getUniverseTheoreticalSupply(universeId) / FORK_THRESHOLD_DIVISOR;
    }

    /// @notice Stubbed implementation of `IZoltar.universes`.
    /// @dev `forkTime` is always `0` (not forking), so resolution tests don't trigger fork
    ///      mirroring. The remaining fields are zero / the shared REP token. Lets tests
    ///      instantiate the mock against the full interface.
    function universes(uint248) external view returns (Universe memory u) {
        u.forkTime = 0;
        u.forkQuestionId = 0;
        u.forkingOutcomeIndex = 0;
        u.reputationToken = repToken;
        u.parentUniverseId = 0;
    }

    function forkUniverse(uint248, uint256) external {
        // no-op
    }

    function deployChild(uint248, uint256) external {
        // no-op
    }
}
