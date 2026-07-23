// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Script, console } from "forge-std/Script.sol";

import { Multiverse } from "src/Multiverse.sol";
import { QueryFeeController } from "src/QueryFeeController.sol";
import { IZoltar } from "src/interfaces/IZoltar.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";

/// @notice Deployment script for the Lituus system: QueryFeeController + Multiverse.
/// @dev Deploy order (see QueryFeeController.setMultiverse): the controller first, then the
///      Multiverse pointing at it, then wire the controller to the Multiverse. Requires an
///      already-deployed Zoltar: the Multiverse constructor reads its question-data and REP
///      token addresses.
///      Env vars: PRIVATE_KEY, ZOLTAR_ADDRESS, GENESIS_UNIVERSE_ID (the Zoltar universe id
///      treated as the Lituus genesis).
contract Deploy is Script {
    function run() external returns (QueryFeeController queryFeeController, Multiverse multiverse) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        IZoltar zoltar = IZoltar(vm.envAddress("ZOLTAR_ADDRESS"));
        uint248 genesisUniverseId = uint248(vm.envUint("GENESIS_UNIVERSE_ID"));

        vm.startBroadcast(deployerKey);
        queryFeeController = new QueryFeeController(genesisUniverseId);
        multiverse = new Multiverse(zoltar, genesisUniverseId, IQueryFeeController(address(queryFeeController)));
        queryFeeController.setMultiverse(address(multiverse));
        vm.stopBroadcast();

        console.log("QueryFeeController deployed at :", address(queryFeeController));
        console.log("Multiverse deployed at         :", address(multiverse));
        console.log("Zoltar                         :", address(zoltar));
        console.log("Genesis universe id            :", uint256(genesisUniverseId));
        console.log("Deployer                       :", deployer);
    }
}
