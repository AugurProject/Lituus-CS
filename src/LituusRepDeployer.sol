// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { ILituusRep } from "./interfaces/ILituusRep.sol";
import { ILituusRepDeployer } from "./interfaces/ILituusRepDeployer.sol";
import { LituusRep } from "./LituusRep.sol";

/// @notice The one place `new LituusRep` happens. The Multiverse used to deploy its vaults inline, which put
///         the whole vault creation code inside the Multiverse bytecode; this contract carries it instead.
///         Only the Multiverse can use it, so every vault this address ever announces is a real one.
/// @dev The Multiverse's constructor deploys the genesis vault through this contract, so the Multiverse has to
///      be known here before it exists: its address is computed ahead (CREATE2 over its creation code, which
///      carries this contract's own address) and passed in. A Multiverse that lands anywhere else fails its
///      own constructor on that first deploy, so a wrong prediction leaves nothing half-built.
contract LituusRepDeployer is ILituusRepDeployer {
    /// @inheritdoc ILituusRepDeployer
    address public immutable MULTIVERSE;

    event LituusRepDeployed(address indexed underlyingToken, address vault);

    error NotMultiverse();
    error ZeroAddress();

    /// @param multiverse The Multiverse this deployer serves, at the address it is about to be deployed to.
    constructor(address multiverse) {
        if (multiverse == address(0)) revert ZeroAddress();
        MULTIVERSE = multiverse;
    }

    /// @inheritdoc ILituusRepDeployer
    function deploy(address underlyingToken, string calldata name, string calldata symbol, uint256 initialRate)
        external
        returns (ILituusRep)
    {
        if (msg.sender != MULTIVERSE) revert NotMultiverse();
        LituusRep vault = new LituusRep(MULTIVERSE, underlyingToken, name, symbol, initialRate);
        emit LituusRepDeployed(underlyingToken, address(vault));
        return vault;
    }
}
