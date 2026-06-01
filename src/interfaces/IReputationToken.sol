// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IReputationToken is IERC20 {
    function mint(address account, uint256 value) external;
    function burn(address account, uint256 value) external;
}
