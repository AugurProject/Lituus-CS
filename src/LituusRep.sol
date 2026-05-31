// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ILituusRep } from "./interfaces/ILituusRep.sol";

contract LituusRep is ERC20, ERC20Burnable, Ownable, ILituusRep {

    using SafeERC20 for IERC20;

    IERC20 public immutable UNDERLYING_TOKEN;

    constructor(address owner, address underlyingToken, string memory name, string memory symbol)
        ERC20(name, symbol)
        Ownable(owner) {
        UNDERLYING_TOKEN = IERC20(underlyingToken);
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function wrap(address sender, uint256 amount) public onlyOwner {
        UNDERLYING_TOKEN.safeTransferFrom(sender, address(this), amount);
        _mint(sender, amount);
    }

    function unwrap(address sender, uint256 amount) public onlyOwner {
        _burn(sender, amount);
        UNDERLYING_TOKEN.safeTransfer(sender, amount);
    }

    // TODO: permit?
}