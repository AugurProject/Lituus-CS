// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";

/// @notice A universe's record with its fields by name, in the order and under the names of Multiverse.Universe.
/// @dev The Multiverse's `universes` getter returns the fields as a positional tuple, where a miscounted comma
///      silently binds a neighbouring field of the same type. Tests read universes through this view instead.
struct UniverseView {
    ILituusRep repToken;
    Multiverse.UniverseState universeState;
    uint48 forkTime;
    bool isCanonical;
    uint248 parent;
    uint248 favoriteChild;
    bool isLituusFork;
    uint128 totalMigratedIn;
    uint128 maxMigratedOut;
    uint128 forkQuery;
    uint128 totalMigratedOut;
    uint128 totalQueryFees;
    uint128 unmigratedSupply;
    uint128 totalTips;
    uint128 carriedTips;
}

/// @notice Reads a universe into a UniverseView: the one place that knows the getter's tuple order.
library UniverseReader {
    function read(Multiverse multiverse, uint248 universeId) internal view returns (UniverseView memory u) {
        (
            u.repToken,
            u.universeState,
            u.forkTime,
            u.isCanonical,
            u.parent,
            u.favoriteChild,
            u.isLituusFork,
            u.totalMigratedIn,
            u.maxMigratedOut,
            u.forkQuery,
            u.totalMigratedOut,
            u.totalQueryFees,
            u.unmigratedSupply,
            u.totalTips,
            u.carriedTips
        ) = multiverse.universes(universeId);
    }
}
