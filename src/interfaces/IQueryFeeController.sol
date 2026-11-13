// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @notice The Multiverse's side of the query fee controller: it asks for a fee and reports what happened.
///         Every call but the preview is Multiverse-only.
interface IQueryFeeController {
    /// @notice Prices a query being created now in `universeId` and records it in the universe's demand
    ///         history. The query is counted after its fee is computed, so it never prices itself.
    /// @param universeId The universe the query is created in.
    /// @return fee The query fee, base fee times the demand modifier, uncapped, in the universe's wREP.
    function chargeQuery(uint248 universeId) external returns (uint256 fee);

    /// @notice Records a query created now in `universeId` without pricing it, for a query paid at a price set
    ///         elsewhere (a query token redemption).
    /// @param universeId The universe the query is created in.
    function recordQuery(uint248 universeId) external;

    /// @notice Records the realized profit of a query resolved now in `universeId`.
    /// @param universeId The universe the query resolved in.
    /// @param profit The wREP the resolution removed from circulation.
    function recordProfit(uint248 universeId, uint256 profit) external;

    /// @notice Seeds a child universe spawned at a fork from its parent: the parent's base fee, and the
    ///         parent's demand and profit history up to the fork trigger, with the frozen time between the
    ///         trigger and the spawn filled at the parent's rates.
    /// @param parentId The forking parent.
    /// @param childId The child being spawned.
    /// @param forkTime The parent's fork trigger time.
    function seedChild(uint248 parentId, uint248 childId, uint256 forkTime) external;

    /// @notice Moves a universe's base fee one monthly step, steered by its realized profits over the last two
    ///         months. Once a month per universe.
    /// @param universeId The universe whose base fee to update.
    function updateBaseFee(uint248 universeId) external;

    /// @notice The fee `chargeQuery` would return now for `universeId`, without recording anything.
    /// @param universeId The universe to price.
    /// @return The uncapped query fee in the universe's wREP.
    function previewFee(uint248 universeId) external view returns (uint256);
}
