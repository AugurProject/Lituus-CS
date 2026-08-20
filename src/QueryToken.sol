// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IQueryToken } from "./interfaces/IQueryToken.sol";

/**
 * @title QueryToken
 * @notice Per-universe ERC20 representing the tokenized right to create queries. One deployed per universe
 *         by the QueryTokenizer, which owns it.
 * @dev `decimals()` is the OZ default 18, and one whole token (1e18) = the right to one query (the NFTX
 *      model): the protocol logic operates in whole queries while the token stays fully ERC20-compatible
 *      for wallets, custody, and AMMs. `mint`/`burn` are owner-only (owner = the QueryTokenizer), exactly
 *      as `LituusRep` is owned by the `Multiverse`.
 */
contract QueryToken is ERC20, Ownable, IQueryToken {
    constructor(address owner, string memory name, string memory symbol) ERC20(name, symbol) Ownable(owner) { }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
