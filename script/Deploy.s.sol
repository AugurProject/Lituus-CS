// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Script, console } from "forge-std/Script.sol";

import { Multiverse } from "src/Multiverse.sol";
import { QueryFeeController } from "src/QueryFeeController.sol";
import { QueryTokenizer } from "src/QueryTokenizer.sol";
import { IZoltar } from "src/interfaces/IZoltar.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";
import { IMultiverse } from "src/interfaces/IMultiverse.sol";

/// @notice Deployment script for the Lituus system: QueryFeeController + QueryTokenizer + Multiverse.
/// @dev Both the controller and the tokenizer are deployed before the Multiverse and passed into its
///      constructor; each then gets its Multiverse back-reference wired via a one-time, deployer-only
///      setter (QueryFeeController.setMultiverse / QueryTokenizer.setMultiverse). Requires an
///      already-deployed Zoltar: the Multiverse constructor reads its question-data and REP token
///      addresses (the tokenizer reads everything, the mint-price cap included, off the Multiverse).
///      Env vars: PRIVATE_KEY, ZOLTAR_ADDRESS, GENESIS_UNIVERSE_ID (the Zoltar universe id
///      treated as the Lituus genesis).
contract Deploy is Script {
    function run()
        external
        returns (QueryFeeController queryFeeController, QueryTokenizer queryTokenizer, Multiverse multiverse)
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        IZoltar zoltar = IZoltar(vm.envAddress("ZOLTAR_ADDRESS"));
        uint248 genesisUniverseId = uint248(vm.envUint("GENESIS_UNIVERSE_ID"));

        vm.startBroadcast(deployerKey);
        queryFeeController = new QueryFeeController(genesisUniverseId);
        queryTokenizer = new QueryTokenizer();
        multiverse = new Multiverse(
            zoltar, genesisUniverseId, IQueryFeeController(address(queryFeeController)), address(queryTokenizer)
        );
        queryFeeController.setMultiverse(address(multiverse));
        queryTokenizer.setMultiverse(IMultiverse(address(multiverse)));
        vm.stopBroadcast();

        console.log("QueryFeeController deployed at :", address(queryFeeController));
        console.log("Multiverse deployed at         :", address(multiverse));
        console.log("QueryTokenizer deployed at     :", address(queryTokenizer));
        console.log("Zoltar                         :", address(zoltar));
        console.log("Genesis universe id            :", uint256(genesisUniverseId));
        console.log("Deployer                       :", deployer);
    }
}
