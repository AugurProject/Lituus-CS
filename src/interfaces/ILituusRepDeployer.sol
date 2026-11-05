// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { ILituusRep } from "./ILituusRep.sol";

/// @notice Deploys Lituus REP vaults for one Multiverse, and for nobody else. Kept outside the Multiverse so the
///         vault's creation code does not count against the Multiverse's own size.
interface ILituusRepDeployer {
    /// @notice Deploys a vault over `underlyingToken` owned by the Multiverse. Only the Multiverse may call.
    /// @param underlyingToken The Zoltar REP token the vault wraps.
    /// @param name The ERC20 name of the share token.
    /// @param symbol The ERC20 symbol of the share token.
    /// @param initialRate The starting assets-per-share rate, 1e18-scaled.
    /// @return The new vault.
    function deploy(address underlyingToken, string calldata name, string calldata symbol, uint256 initialRate)
        external
        returns (ILituusRep);

    /// @notice The Multiverse this deployer serves, fixed at construction.
    function MULTIVERSE() external view returns (address);
}
