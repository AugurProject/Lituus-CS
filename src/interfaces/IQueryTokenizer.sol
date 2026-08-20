// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IQueryToken } from "./IQueryToken.sol";

/// @notice The Query Token protocol: a single immutable contract that pools Lituus REP and issues a
///         per-universe QueryToken ERC20. Amounts are in whole queries (each = 1e18 QueryToken wei).
interface IQueryTokenizer {
    function mint(uint248 universeId, uint256 amount) external;
    function redeem(uint248 universeId, string calldata question, uint8 numberOfOutcomes) external;
    /// @dev Not implemented yet
    function migrate(uint248 parentUniverseId, uint248 childUniverseId, uint256 amount) external;
    function token(uint248 universeId) external view returns (IQueryToken);
    function pooledRep(uint248 universeId) external view returns (uint256);
}
