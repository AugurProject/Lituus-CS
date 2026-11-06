// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { ILituusRep } from "./interfaces/ILituusRep.sol";
import { IQueryToken } from "./interfaces/IQueryToken.sol";
import { ITokenDeployer } from "./interfaces/ITokenDeployer.sol";
import { IZoltarRepToken } from "./interfaces/IZoltarRepToken.sol";
import { LituusRep } from "./LituusRep.sol";
import { QueryToken } from "./QueryToken.sol";

/// @notice The one place `new LituusRep` and `new QueryToken` happen. The Multiverse and the QueryTokenizer used to
///         deploy their tokens inline, which put the tokens' creation code inside their bytecode; this contract
///         carries it instead.
contract TokenDeployer is ITokenDeployer {
    event LituusRepDeployed(address indexed owner, address indexed underlyingToken, address vault);

    /// @inheritdoc ITokenDeployer
    function deployLituusRep(address zoltarRepToken, uint256 initialRate) external returns (ILituusRep) {
        (string memory name, string memory symbol) = _nameAndSymbol(zoltarRepToken, "Lituus Reputation Token", "wREP");
        LituusRep vault = new LituusRep(msg.sender, zoltarRepToken, name, symbol, initialRate);
        emit LituusRepDeployed(msg.sender, zoltarRepToken, address(vault));
        return vault;
    }

    /// @inheritdoc ITokenDeployer
    function deployQueryToken(address zoltarRepToken) external returns (IQueryToken) {
        (string memory name, string memory symbol) = _nameAndSymbol(zoltarRepToken, "Lituus Query Token", "QT");
        return new QueryToken(msg.sender, name, symbol);
    }

    /// @dev "<namePrefix> <n>" / "<symbolPrefix><n>", <n> being the Zoltar REP token's repNumber (0 for the
    ///      genesis).
    function _nameAndSymbol(address zoltarRepToken, string memory namePrefix, string memory symbolPrefix)
        private
        view
        returns (string memory name, string memory symbol)
    {
        string memory number = Strings.toString(_repNumber(zoltarRepToken));
        return (string.concat(namePrefix, " ", number), string.concat(symbolPrefix, number));
    }

    /// @dev Zoltar's repNumber, or 0 for the genesis REPv2, which has no repNumber and reverts on the call. 0 is
    ///      free for the genesis: Zoltar numbers children from 1.
    function _repNumber(address zoltarRepToken) private view returns (uint256) {
        try IZoltarRepToken(zoltarRepToken).repNumber() returns (uint256 repNumber) {
            return repNumber;
        } catch {
            return 0;
        }
    }
}
