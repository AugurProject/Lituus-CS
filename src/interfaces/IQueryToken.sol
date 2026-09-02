// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Per-universe Query Token ERC20. One whole token (1e18) = the right to one query.
///         `mint`/`burn` are owner-only (the owner is the QueryTokenizer).
interface IQueryToken is IERC20 {
    /// @notice Mints `amount` token wei to `to`. Only the owner may call.
    /// @param to The account receiving the minted tokens.
    /// @param amount The amount to mint, in token wei (1e18 per whole query).
    function mint(address to, uint256 amount) external;

    /// @notice Burns `amount` token wei from `from`. Only the owner may call.
    /// @dev Reverts with ERC20InsufficientBalance if `from` holds less than `amount`.
    /// @param from The account whose tokens are burned.
    /// @param amount The amount to burn, in token wei (1e18 per whole query).
    function burn(address from, uint256 amount) external;
}
