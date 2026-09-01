// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Lituus REP (wREP): a share token over an underlying Zoltar REP vault.
/// @dev Share-based accounting with a stored exchange rate. The rate (underlying assets per share,
///      1e18-scaled) changes ONLY in burnShares and only upward: wrapping and unwrapping convert at
///      the stored rate, so they cannot move it, and direct underlying transfers to the vault are
///      inert (assets are tracked in an internal ledger, not via balanceOf). The stored rate
///      persists when the vault empties, so supply regrown from zero keeps the accrued
///      appreciation instead of resetting to 1:1.
///
///      Rounding always favors the vault: amounts leaving the vault (shares minted on a wrap,
///      underlying released on an unwrap) round down, and amounts entering the vault (underlying
///      pulled when the caller fixes the shares, shares burned when the caller fixes the
///      underlying) round up. Retained remainders stay in the vault and fold into the rate at the
///      next burnShares recompute, socializing them across all holders.
///
///      All state-changing functions are restricted to the owner (the Multiverse); the vault
///      exposes no public deposit/redeem surface. The underlying is assumed to be a standard
///      ERC20 (no transfer fees, no rebasing, no hooks).
interface ILituusRep is IERC20 {
    /* ================================================== EVENTS ================================================= */

    /// @notice Emitted when underlying is wrapped into shares.
    event Wrapped(address indexed sender, uint256 assets, uint256 shares);

    /// @notice Emitted when shares are unwrapped back into underlying.
    event Unwrapped(address indexed sender, uint256 shares, uint256 assets);

    /// @notice Emitted when shares are burned from the owner's balance, moving the rate.
    /// @param shares The amount of shares burned.
    /// @param newRate The assets-per-share rate (1e18-scaled) in effect after the burn.
    event SharesBurned(uint256 shares, uint256 newRate);

    /// @notice Emitted when unwrapping is paused or unpaused.
    event UnwrapPauseSet(bool paused);

    /* ============================================== WRAP FUNCTIONS ============================================= */

    /// @notice Wraps an exact amount of underlying REP into shares for `sender`.
    /// @dev Pulls `assets` of underlying from `sender` (requires prior approval), credits the
    ///      internal asset ledger, and mints `assets * SCALE / rate` shares rounded DOWN. Reverts
    ///      with ZeroShares if the rounded share amount is zero, so underlying cannot be donated
    ///      through a wrap. The rate is unchanged. Only the owner may call.
    /// @param sender The account providing the underlying and receiving the shares.
    /// @param assets The exact amount of underlying REP to wrap.
    /// @return shares The amount of shares minted to `sender`.
    function wrap(address sender, uint256 assets) external returns (uint256 shares);

    /// @notice Wraps underlying REP into an exact amount of shares for `sender`.
    /// @dev Mints exactly `shares` to `sender` and pulls `shares * rate / SCALE` of underlying
    ///      rounded UP. Reverts with ZeroShares on a zero share amount. The rate is unchanged.
    ///      Only the owner may call.
    /// @param sender The account providing the underlying and receiving the shares.
    /// @param shares The exact amount of shares to mint.
    /// @return assets The amount of underlying REP pulled from `sender`.
    function wrapShares(address sender, uint256 shares) external returns (uint256 assets);

    /* ============================================= UNWRAP FUNCTIONS ============================================ */

    /// @notice Unwraps an exact amount of `sender`'s shares back into underlying REP.
    /// @dev Burns `shares` from `sender`, debits the internal asset ledger by
    ///      `shares * rate / SCALE` rounded DOWN, and transfers that underlying to `sender`.
    ///      Reverts with ZeroAssets if the rounded underlying amount is zero, so shares cannot be
    ///      burned for nothing, and with UnwrapIsPaused while unwrapping is paused. The rate is
    ///      unchanged. Only the owner may call.
    /// @param sender The account whose shares are burned and who receives the underlying.
    /// @param shares The exact amount of shares to unwrap.
    /// @return assets The amount of underlying REP released to `sender`.
    function unwrap(address sender, uint256 shares) external returns (uint256 assets);

    /// @notice Unwraps `sender`'s shares into an exact amount of underlying REP.
    /// @dev Transfers exactly `assets` of underlying to `sender` and burns
    ///      `assets * SCALE / rate` shares rounded UP. Reverts with ZeroAssets on a zero
    ///      underlying amount and with UnwrapIsPaused while unwrapping is paused. The rate is
    ///      unchanged. Only the owner may call.
    /// @param sender The account whose shares are burned and who receives the underlying.
    /// @param assets The exact amount of underlying REP to receive.
    /// @return shares The amount of shares burned from `sender`.
    function unwrapAssets(address sender, uint256 assets) external returns (uint256 shares);

    /* ============================================== BURN FUNCTIONS ============================================= */

    /// @notice Burns shares from the owner's balance and recomputes the rate.
    /// @dev The only operation that moves the rate. Burning reduces the share supply while the
    ///      asset ledger is untouched, so the recomputed rate (`totalAssets * SCALE / totalSupply`,
    ///      rounded down) can only increase; retained rounding remainders are socialized into it.
    ///      If the burn empties the supply, the recompute is skipped and the previous rate
    ///      persists. Only the owner may call.
    /// @param shares The amount of shares to burn from the owner's balance.
    function burnShares(uint256 shares) external;

    /* ============================================== ADMIN FUNCTIONS ============================================ */

    /// @notice Pauses or unpauses unwrapping. Only the owner may call.
    /// @dev Wrapping and burning are unaffected. Intended for windows during which the underlying
    ///      must not leave the vault, such as a fork migration.
    /// @param paused True to pause unwrapping, false to unpause.
    function setUnwrapPaused(bool paused) external;

    /* =============================================== VIEW FUNCTIONS ============================================ */

    /// @notice Converts an underlying amount to shares at the stored rate, rounded down.
    /// @dev The amount of shares a wrap of `assets` mints.
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Converts a share amount to underlying at the stored rate, rounded down.
    /// @dev The amount of underlying an unwrap of `shares` releases.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Converts an underlying amount to shares at the stored rate, rounded up.
    /// @dev The amount of shares an unwrapAssets of `assets` burns: what a caller fixing the
    ///      underlying to receive must hold. At most one wei above convertToShares.
    function convertToSharesUp(uint256 assets) external view returns (uint256 shares);

    /// @notice Converts a share amount to underlying at the stored rate, rounded up.
    /// @dev The amount of underlying a wrapShares of `shares` pulls: what a caller fixing the
    ///      shares to receive must hold and approve. At most one wei above convertToAssets.
    function convertToAssetsUp(uint256 shares) external view returns (uint256 assets);

    /// @notice The stored exchange rate: underlying assets per share, 1e18-scaled.
    /// @dev Genesis universes start at 1:1; a child universe's vault starts at its parent's rate
    /// at fork time, so accrued appreciation carries across universes.
    function rate() external view returns (uint256);

    /// @notice The underlying REP tracked by the internal ledger.
    /// @dev Moves only on wraps and unwraps. Direct underlying transfers to the vault are not
    /// reflected here and are unrecoverable.
    function totalAssets() external view returns (uint256);

    /// @notice Whether unwrapping is paused.
    function unwrapPaused() external view returns (bool);
}
