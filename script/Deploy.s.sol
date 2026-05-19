// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Script, console } from "forge-std/Script.sol";

import { Counter } from "src/Counter.sol";

/// @notice Deployment script for Counter.
contract Deploy is Script {
    function run() external returns (Counter counter) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);

        vm.startBroadcast(deployerKey);
        counter = new Counter(owner);
        vm.stopBroadcast();

        console.log("Counter deployed at :", address(counter));
        console.log("Owner set to        :", owner);
        console.log("Deployer            :", deployer);
    }
}
