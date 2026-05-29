// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILituusRep is IERC20 {
    function wrap(uint256 amount) external;
    function unwrap(uint256 amount) external;
}