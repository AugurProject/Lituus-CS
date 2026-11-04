// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { ILituusRep } from "./interfaces/ILituusRep.sol";
import { ILituusRepDeployer } from "./interfaces/ILituusRepDeployer.sol";
import { LituusRep } from "./LituusRep.sol";

/// @notice The one place `new LituusRep` happens. The Multiverse used to deploy its vaults inline, which put
///         the whole vault creation code inside the Multiverse bytecode; this contract carries it instead.
contract LituusRepDeployer is ILituusRepDeployer {
    event LituusRepDeployed(address indexed owner, address indexed underlyingToken, address vault);

    /// @inheritdoc ILituusRepDeployer
    function deploy(address underlyingToken, string calldata name, string calldata symbol, uint256 initialRate)
        external
        returns (ILituusRep)
    {
        LituusRep vault = new LituusRep(msg.sender, underlyingToken, name, symbol, initialRate);
        emit LituusRepDeployed(msg.sender, underlyingToken, address(vault));
        return vault;
    }
}
