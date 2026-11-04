// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Script, console } from "forge-std/Script.sol";

import { LituusRepDeployer } from "src/LituusRepDeployer.sol";
import { Multiverse } from "src/Multiverse.sol";
import { QueryFeeController } from "src/QueryFeeController.sol";
import { QueryTokenizer } from "src/QueryTokenizer.sol";
import { IZoltar } from "src/interfaces/IZoltar.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";
import { IMultiverse } from "src/interfaces/IMultiverse.sol";
import { IPermit2 } from "src/interfaces/IPermit2.sol";

/// @notice Deployment script for the Lituus system: QueryFeeController + QueryTokenizer + LituusRepDeployer +
///         Multiverse.
/// @dev The controller, the tokenizer and the vault deployer are deployed before the Multiverse and passed
///      into its constructor (the constructor deploys the genesis vault through the deployer); the controller
///      and the tokenizer then get their Multiverse back-reference wired via a one-time, deployer-only
///      setter (QueryFeeController.setMultiverse / QueryTokenizer.setMultiverse). Requires an
///      already-deployed Zoltar: the Multiverse constructor reads its question-data and REP token
///      addresses (the tokenizer reads everything, the mint-price cap included, off the Multiverse).
///      Env vars: PRIVATE_KEY, ZOLTAR_ADDRESS, GENESIS_UNIVERSE_ID (the Zoltar universe id
///      treated as the Lituus genesis), and optionally PERMIT2_ADDRESS (defaults to the canonical Permit2).
contract Deploy is Script {
    // Time periods baked into the Multiverse as immutables.
    uint256 internal constant MIGRATION_DURATION = 30 days;
    uint256 internal constant REPORTING_PERIOD = 3 days;
    uint256 internal constant APPEAL_PERIOD = 1 days;
    // Uniswap's Permit2, deployed at the same address on every chain it exists on.
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run()
        external
        returns (
            QueryFeeController queryFeeController,
            QueryTokenizer queryTokenizer,
            LituusRepDeployer vaultDeployer,
            Multiverse multiverse
        )
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        IZoltar zoltar = IZoltar(vm.envAddress("ZOLTAR_ADDRESS"));
        uint248 genesisUniverseId = uint248(vm.envUint("GENESIS_UNIVERSE_ID"));
        IPermit2 permit2 = IPermit2(vm.envOr("PERMIT2_ADDRESS", CANONICAL_PERMIT2));

        vm.startBroadcast(deployerKey);
        queryFeeController = new QueryFeeController(genesisUniverseId);
        queryTokenizer = new QueryTokenizer(permit2);
        vaultDeployer = new LituusRepDeployer();
        multiverse = new Multiverse(
            zoltar,
            genesisUniverseId,
            IQueryFeeController(address(queryFeeController)),
            address(queryTokenizer),
            vaultDeployer,
            permit2,
            MIGRATION_DURATION,
            REPORTING_PERIOD,
            APPEAL_PERIOD
        );
        queryFeeController.setMultiverse(address(multiverse));
        queryTokenizer.setMultiverse(IMultiverse(address(multiverse)));
        vm.stopBroadcast();

        console.log("QueryFeeController deployed at :", address(queryFeeController));
        console.log("Multiverse deployed at         :", address(multiverse));
        console.log("QueryTokenizer deployed at     :", address(queryTokenizer));
        console.log("LituusRepDeployer deployed at  :", address(vaultDeployer));
        console.log("Permit2                        :", address(permit2));
        console.log("Zoltar                         :", address(zoltar));
        console.log("Genesis universe id            :", uint256(genesisUniverseId));
        console.log("Deployer                       :", deployer);
    }
}
