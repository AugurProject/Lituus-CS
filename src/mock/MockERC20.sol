// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { IReputationToken } from "../interfaces/IReputationToken.sol";

contract MockERC20 is ERC20, IReputationToken {
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
