// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { ILituusRep } from "./ILituusRep.sol";

/// @notice The subset of the Multiverse the QueryTokenizer (and deploy script) depend on.
interface IMultiverse {
    /// @notice Creates a query paying a tokenizer-supplied price (the redeemed token's pooled average).
    ///         Never forwards to the heir: reverts unless the universe itself is Active/Forming.
    ///         `creator` (the redeemer) is emitted as QueryCreated's creator.
    function createQueryFromTokenizer(
        uint248 universeId,
        string calldata question,
        uint8 numberOfOutcomes,
        uint256 fee,
        address creator
    ) external;

    /// @notice The current query fee (base × demand modifier, uncapped) — read-only;
    ///         used to price minting of query tokens. Never forwards to the heir: reverts unless the
    ///         universe itself is Active/Forming.
    function previewQueryFeeUncapped(uint248 universeId) external view returns (uint256);

    /// @notice The Lituus REP token for a universe (what the QueryTokenizer pools and pays fees in).
    function repTokenOf(uint248 universeId) external view returns (ILituusRep);
}
