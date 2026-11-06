// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { ILituusRep } from "./ILituusRep.sol";
import { IQueryToken } from "./IQueryToken.sol";

/// @notice Deploys the per-universe Lituus tokens on behalf of the caller: the wREP vaults for the Multiverse and
///         the query tokens for the QueryTokenizer. Kept outside both so the tokens' creation code does not count
///         against their own size, and so every universe token is named in one place.
/// @dev Tokens follow Zoltar's REP naming: Zoltar names the REP token of its n-th child universe
///      "Augur Reputation <n>" / "REP<n>", and the Lituus tokens of that universe reuse <n>. The genesis REP is the
///      external REPv2, which Zoltar does not number, so the genesis tokens take 0 (Zoltar numbers children from 1).
///      Permissionless on purpose: a token belongs to whoever calls, so a stranger only ever gets a token of
///      their own that no universe points at.
interface ITokenDeployer {
    /// @notice Deploys a wREP vault over `zoltarRepToken` owned by the caller, named
    ///         "Lituus Reputation Token <n>" / "wREP<n>".
    /// @param zoltarRepToken The Zoltar REP token the vault wraps.
    /// @param initialRate The starting assets-per-share rate, 1e18-scaled.
    /// @return The new vault.
    function deployLituusRep(address zoltarRepToken, uint256 initialRate) external returns (ILituusRep);

    /// @notice Deploys a query token owned by the caller for the universe of `zoltarRepToken`, named
    ///         "Lituus Query Token <n>" / "QT<n>".
    /// @param zoltarRepToken The Zoltar REP token of the universe the query token belongs to.
    /// @return The new query token.
    function deployQueryToken(address zoltarRepToken) external returns (IQueryToken);
}
