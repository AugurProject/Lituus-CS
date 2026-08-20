// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Per-universe Query Token ERC20. One whole token (1e18) = the right to one query.
///         `mint`/`burn` are owner-only (the owner is the QueryTokenizer).
interface IQueryToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}
