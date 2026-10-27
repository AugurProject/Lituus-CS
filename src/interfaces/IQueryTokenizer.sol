// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IQueryToken } from "./IQueryToken.sol";

/// @notice The Query Token protocol: a single immutable contract that pools Lituus REP and issues a
///         per-universe QueryToken ERC20. Amounts are in whole queries (each = 1e18 QueryToken wei).
interface IQueryTokenizer {
    /* ============================================== CORE ACTIONS =============================================== */

    /// @notice Mints `amount` whole Query Tokens for the caller, depositing the mint price per token —
    ///         the full demand-inclusive query fee plus a fixed 10% premium, capped at half the fork
    ///         threshold (all in wREP) — times `amount` in Lituus REP into the universe's pool.
    /// @dev The caller must approve this contract for the universe's Lituus REP. The universe's
    ///      QueryToken is deployed lazily on the first mint. Reverts with ZeroAmount on a zero amount,
    ///      with ZeroCost if the total cost rounds to zero (free tokens would dilute the pool average),
    ///      and pricing reverts for a nonexistent or non-current universe.
    /// @param universeId The universe to mint tokens for.
    /// @param amount Number of whole query rights to mint.
    function mint(uint248 universeId, uint256 amount) external;

    /// @notice Redeems one whole Query Token: destroys it and creates a normal Query in the oracle on
    ///         the caller's behalf, paying the pool's per-token average as the fee.
    /// @dev Removing exactly the average leaves the average unchanged for remaining holders. The fee is
    ///      paid whole, uncapped — the average never decays while the fork threshold can decline, so it
    ///      may exceed half the threshold; the oracle then clamps the first report's stake, not the fee.
    ///      Reverts with
    ///      QueryTokenNotExisting if the universe has no token, with NoWholeTokens if the supply is
    ///      below one whole token, and with ERC20InsufficientBalance if the caller holds less than one.
    /// @param universeId The universe to redeem in.
    /// @param question The question text for the created query.
    /// @param numberOfOutcomes The number of reportable outcomes.
    function redeem(uint248 universeId, string calldata question, uint8 numberOfOutcomes) external;

    /* ============================================= FORK MIGRATION ============================================== */

    /// @notice Migrates `amount` whole Query Tokens from a forked parent universe into the child of
    ///         `childOutcome`: the parent tokens burn, their share of the pool (pooledRep × amount /
    ///         wholeSupply) leaves the parent through the Multiverse as a counted migration vote for the
    ///         child, and the same number of the child's Query Tokens is minted to the caller.
    /// @dev Query tokens are never forwarded to the heir: once a universe forks, minting and redeeming
    ///      freeze there and migration is the only path to a child. The share is rounded down, so the
    ///      holders who stay never lose and the last tokens out take the whole pool; what arrives joins the
    ///      child's pool in child wREP and blends with the child's own mints. Tokens not migrated inside
    ///      the window stay in the parent with their share of the pool, worthless. The parent's state,
    ///      the window and the child's existence are checked by the Multiverse (see Multiverse.migrate).
    ///      Reverts with ZeroAmount on a zero amount, with QueryTokenNotExisting if the parent has no
    ///      token, with NoWholeTokens if its supply is below one whole token, and with
    ///      ERC20InsufficientBalance if the caller holds fewer whole tokens than `amount`.
    /// @param parentUniverseId The forked (parent) universe.
    /// @param childOutcome The forking query's outcome whose child to migrate into, as passed to
    ///        spawnChildUniverse.
    /// @param amount Number of whole query rights to migrate.
    function migrate(uint248 parentUniverseId, uint256 childOutcome, uint256 amount) external;

    /* =============================================== VIEW FUNCTIONS ============================================ */

    /// @notice The universe's QueryToken ERC20.
    /// @dev Zero address until the first mint into the universe deploys it.
    function token(uint248 universeId) external view returns (IQueryToken);

    /// @notice The Lituus REP pooled in the universe, backing its outstanding query tokens.
    /// @dev Grows by the full mint cost on each mint and by what a migration brings in from the parent;
    ///      shrinks by the per-token average on each redemption and by the migrated tokens' share on each
    ///      migration out, so only mints (at new fees) and arrivals from a parent move the average.
    function pooledRep(uint248 universeId) external view returns (uint256);
}
