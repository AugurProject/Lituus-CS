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
///         carries it instead. Only the Multiverse can deploy vaults, so every vault this address ever announces is
///         a real one.
/// @dev The Multiverse's constructor deploys the genesis vault through this contract, so the Multiverse has to
///      be known here before it exists: its address is computed ahead (CREATE2 over its creation code, which
///      carries this contract's own address) and passed in. A Multiverse that lands anywhere else fails its
///      own constructor on that first deploy, so a wrong prediction leaves nothing half-built.
contract TokenDeployer is ITokenDeployer {
    /// @inheritdoc ITokenDeployer
    address public immutable MULTIVERSE;

    event LituusRepDeployed(address indexed underlyingToken, address vault);

    error NotMultiverse();
    error ZeroAddress();

    /// @param multiverse The Multiverse this deployer serves, at the address it is about to be deployed to.
    constructor(address multiverse) {
        if (multiverse == address(0)) revert ZeroAddress();
        MULTIVERSE = multiverse;
    }

    /// @inheritdoc ITokenDeployer
    function deployLituusRep(address zoltarRepToken, uint256 initialRate) external returns (ILituusRep) {
        if (msg.sender != MULTIVERSE) revert NotMultiverse();
        (string memory name, string memory symbol) = _nameAndSymbol(zoltarRepToken, "Lituus Reputation Token", "wREP");
        LituusRep vault = new LituusRep(MULTIVERSE, zoltarRepToken, name, symbol, initialRate);
        emit LituusRepDeployed(zoltarRepToken, address(vault));
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
