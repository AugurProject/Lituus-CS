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
import { ITokenDeployer } from "src/interfaces/ITokenDeployer.sol";
import { IPermit2 } from "src/interfaces/IPermit2.sol";

/// @notice Deployment script for the Lituus system: QueryFeeController + QueryTokenizer + TokenDeployer +
///         Multiverse.
/// @dev The controller, the tokenizer and the token deployer are deployed before the Multiverse and passed
///      into its constructor (the constructor deploys the genesis vault through the deployer), and each of the
///      three serves that one Multiverse, fixed in its own constructor. So the Multiverse's address is computed
///      before any of them exists: the three land at the broadcasting account's next three CREATE addresses, in
///      that order, and the Multiverse at the CREATE2 address of its creation code with those three addresses
///      among the constructor arguments, under MULTIVERSE_SALT and the standard CREATE2 deployer forge routes
///      `new C{salt: ...}` through. The tokenizer also takes the token deployer's predicted address, since it
///      deploys its query tokens through it. The script checks every predicted address; a Multiverse landing
///      anywhere else would fail its own constructor on the genesis vault.
///      Requires an
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
///      treated as the Lituus genesis), and optionally PERMIT2_ADDRESS (defaults to the canonical Permit2) and
///      MULTIVERSE_SALT (the CREATE2 salt, defaults to the hash of "Lituus Multiverse").
contract Deploy is Script {
    // Time periods baked into the Multiverse as immutables.
    uint256 internal constant MIGRATION_DURATION = 30 days;
    uint256 internal constant REPORTING_PERIOD = 3 days;
    uint256 internal constant APPEAL_PERIOD = 1 days;
    // Uniswap's Permit2, deployed at the same address on every chain it exists on.
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // The CREATE2 salt of the Multiverse.
    bytes32 internal constant DEFAULT_MULTIVERSE_SALT = keccak256("Lituus Multiverse");

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
        bytes32 salt = vm.envOr("MULTIVERSE_SALT", DEFAULT_MULTIVERSE_SALT);

        vm.startBroadcast(deployerKey);
        // The account's next three contracts, in deploy order; with them the Multiverse's creation code is
        // complete and its CREATE2 address follows.
        uint64 nonce = vm.getNonce(deployer);
        address controllerAddress = vm.computeCreateAddress(deployer, nonce);
        address tokenizerAddress = vm.computeCreateAddress(deployer, nonce + 1);
        address tokenDeployerAddress = vm.computeCreateAddress(deployer, nonce + 2);
        bytes memory multiverseArguments = abi.encode(
            zoltar,
            genesisUniverseId,
            IQueryFeeController(controllerAddress),
            tokenizerAddress,
            ITokenDeployer(tokenDeployerAddress),
            permit2,
            MIGRATION_DURATION,
            REPORTING_PERIOD,
            APPEAL_PERIOD
        );
        address predictedMultiverse = vm.computeCreate2Address(
            salt, keccak256(abi.encodePacked(type(Multiverse).creationCode, multiverseArguments))
        );

        queryFeeController = new QueryFeeController(genesisUniverseId, predictedMultiverse);
        require(address(queryFeeController) == controllerAddress, "fee controller landed elsewhere");
        queryTokenizer =
            new QueryTokenizer(permit2, ITokenDeployer(tokenDeployerAddress), IMultiverse(predictedMultiverse));
        require(address(queryTokenizer) == tokenizerAddress, "tokenizer landed elsewhere");
        tokenDeployer = new TokenDeployer(predictedMultiverse);
        require(address(tokenDeployer) == tokenDeployerAddress, "token deployer landed elsewhere");
        multiverse = new Multiverse{ salt: salt }(
            zoltar,
            genesisUniverseId,
            queryFeeController,
            address(queryTokenizer),
            tokenDeployer,
            permit2,
            MIGRATION_DURATION,
            REPORTING_PERIOD,
            APPEAL_PERIOD
        );
        require(address(multiverse) == predictedMultiverse, "Multiverse landed elsewhere");
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
