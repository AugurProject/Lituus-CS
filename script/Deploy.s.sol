// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Script, console } from "forge-std/Script.sol";

import { TokenDeployer } from "src/TokenDeployer.sol";
import { Multiverse } from "src/Multiverse.sol";
import { QueryFeeController } from "src/QueryFeeController.sol";
import { QueryTokenizer } from "src/QueryTokenizer.sol";
import { IZoltar } from "src/interfaces/IZoltar.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";
import { IMultiverse } from "src/interfaces/IMultiverse.sol";
import { IPermit2 } from "src/interfaces/IPermit2.sol";

/// @notice Deployment script for the Lituus system: QueryFeeController + TokenDeployer + QueryTokenizer +
///         Multiverse.
/// @dev The token deployer comes first: the tokenizer takes it in its constructor (it deploys the query tokens
///      through it). The controller, the tokenizer and the token deployer are deployed before the Multiverse and
///      passed into its constructor (the constructor deploys the genesis vault through the deployer); the controller
///      and the tokenizer then get their Multiverse back-reference wired via a one-time, deployer-only
///      setter (QueryFeeController.setMultiverse / QueryTokenizer.setMultiverse). Requires an
///      already-deployed Zoltar: the Multiverse constructor reads its question-data and REP token
///      addresses (the tokenizer reads everything, the mint-price cap included, off the Multiverse).
///      The Multiverse links the external library ForkLib, which forge script handles before deploying it:
///      unless an address is given (`--libraries` or `libraries` in foundry.toml), it computes ForkLib's
///      CREATE2 address from the `create2_deployer` and `create2_library_salt` config (defaults: the standard
///      deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C and salt 0) and ForkLib's creation code, checks
///      the chain at that address and deploys ForkLib there only if no code is present, then links that
///      address. That address is derived from the exact bytecode, so an existing copy is always this same
///      build, and any change to ForkLib yields a new address and a fresh deploy. On a chain where the
///      CREATE2 deployer has no code, forge instead deploys ForkLib with a plain CREATE from the broadcasting
///      account: the address then follows the account's nonce, not the bytecode, so the guarantees above do
///      not hold. The broadcast file lists the linked address under `libraries`. Deploying or verifying the
///      Multiverse any other way needs `--libraries src/libraries/ForkLib.sol:ForkLib:<address>`.
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
            TokenDeployer tokenDeployer,
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
        tokenDeployer = new TokenDeployer();
        queryTokenizer = new QueryTokenizer(permit2, tokenDeployer);
        multiverse = new Multiverse(
            zoltar,
            genesisUniverseId,
            IQueryFeeController(address(queryFeeController)),
            address(queryTokenizer),
            tokenDeployer,
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
        console.log("TokenDeployer deployed at      :", address(tokenDeployer));
        console.log("Permit2                        :", address(permit2));
        console.log("Zoltar                         :", address(zoltar));
        console.log("Genesis universe id            :", uint256(genesisUniverseId));
        console.log("Deployer                       :", deployer);
    }
}
