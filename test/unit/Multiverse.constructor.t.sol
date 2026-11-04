// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { LituusRep } from "src/LituusRep.sol";
import { LituusRepDeployer } from "src/LituusRepDeployer.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { ILituusRepDeployer } from "src/interfaces/ILituusRepDeployer.sol";
import { IZoltar } from "src/interfaces/IZoltar.sol";
import { IQueryFeeController } from "src/interfaces/IQueryFeeController.sol";
import { MultiverseFixtures } from "./Multiverse.fixtures.sol";

contract MultiverseConstructorTest is MultiverseFixtures {
    function test_RevertWhen_ZoltarIsZero() public {
        vm.expectRevert(Multiverse.ZeroAddress.selector);
        new Multiverse(
            IZoltar(address(0)),
            GENESIS_UID,
            feeCtl,
            queryTokenizerStub,
            vaultDeployer,
            permit2,
            MIGRATION_DURATION,
            REPORTING_PERIOD,
            APPEAL_PERIOD
        );
    }

    function test_RevertWhen_QueryFeeControllerIsZero() public {
        vm.expectRevert(Multiverse.ZeroAddress.selector);
        new Multiverse(
            zoltar,
            GENESIS_UID,
            IQueryFeeController(address(0)),
            queryTokenizerStub,
            vaultDeployer,
            permit2,
            MIGRATION_DURATION,
            REPORTING_PERIOD,
            APPEAL_PERIOD
        );
    }

    function test_RevertWhen_QueryTokenizerIsZero() public {
        vm.expectRevert(Multiverse.ZeroAddress.selector);
        new Multiverse(
            zoltar,
            GENESIS_UID,
            feeCtl,
            address(0),
            vaultDeployer,
            permit2,
            MIGRATION_DURATION,
            REPORTING_PERIOD,
            APPEAL_PERIOD
        );
    }

    function test_RevertWhen_VaultDeployerIsZero() public {
        vm.expectRevert(Multiverse.ZeroAddress.selector);
        new Multiverse(
            zoltar,
            GENESIS_UID,
            feeCtl,
            queryTokenizerStub,
            ILituusRepDeployer(address(0)),
            permit2,
            MIGRATION_DURATION,
            REPORTING_PERIOD,
            APPEAL_PERIOD
        );
    }

    function test_Constructor_SetsImmutables() public {
        uint256 deployTime = START_TIME + 5 days;
        vm.warp(deployTime);
        Multiverse newMultiverse = new Multiverse(
            zoltar,
            GENESIS_UID,
            feeCtl,
            queryTokenizerStub,
            vaultDeployer,
            permit2,
            MIGRATION_DURATION,
            REPORTING_PERIOD,
            APPEAL_PERIOD
        );

        assertEq(address(newMultiverse.ZOLTAR()), address(zoltar));
        assertEq(address(newMultiverse.VAULT_DEPLOYER()), address(vaultDeployer));
        assertEq(newMultiverse.GENESIS_UNIVERSE_ID(), GENESIS_UID);
        assertEq(address(newMultiverse.QUERY_FEE_CONTROLLER()), address(feeCtl));
        assertEq(newMultiverse.GENESIS_TIMESTAMP(), deployTime);
        assertEq(address(newMultiverse.QUERY_TOKENIZER()), address(queryTokenizerStub));
        assertEq(newMultiverse.MIGRATION_DURATION(), MIGRATION_DURATION);
        assertEq(newMultiverse.REPORTING_PERIOD(), REPORTING_PERIOD);
        assertEq(newMultiverse.APPEAL_PERIOD(), APPEAL_PERIOD);
    }

    function test_Constructor_SetsTimePeriods() public {
        // Values distinct from the fixture defaults, so the assertions prove the immutables come from
        // the constructor arguments rather than from any baked-in constant.
        Multiverse newMultiverse = new Multiverse(
            zoltar, GENESIS_UID, feeCtl, queryTokenizerStub, vaultDeployer, permit2, 30 days, 2 days, 12 hours
        );

        assertEq(newMultiverse.MIGRATION_DURATION(), 30 days);
        assertEq(newMultiverse.REPORTING_PERIOD(), 2 days);
        assertEq(newMultiverse.APPEAL_PERIOD(), 12 hours);
    }

    function test_Constructor_InitializesGenesisUniverse() public {
        Multiverse newMultiverse = new Multiverse(
            zoltar,
            GENESIS_UID,
            feeCtl,
            queryTokenizerStub,
            vaultDeployer,
            permit2,
            MIGRATION_DURATION,
            REPORTING_PERIOD,
            APPEAL_PERIOD
        );

        (
            ILituusRep repToken,
            Multiverse.UniverseState universeState,
            uint48 forkTime,
            bool isCanonical,
            uint248 parent,
            uint248 favoriteChild,
            bool isLituusFork,
            uint128 totalMigratedIn,
            uint128 maxMigratedOut,
            uint256 forkQuery,
            uint256 totalMigratedOut,
            uint256 totalQueryFees,
            uint256 unmigratedSupply
        ) = newMultiverse.universes(GENESIS_UID);

        assertTrue(address(repToken) != address(0));
        assertEq(uint8(universeState), uint8(Multiverse.UniverseState.Active));
        // forkTime = the moment the universe's own fork split it; 0 until the genesis forks.
        assertEq(forkTime, 0);
        assertTrue(isCanonical);
        assertEq(parent, 0);
        assertEq(favoriteChild, 0);
        assertFalse(isLituusFork);
        assertEq(totalMigratedIn, 0);
        assertEq(maxMigratedOut, 0);
        assertEq(forkQuery, 0);
        // totalMigratedOut stays 0 until the universe forks and migration begins.
        assertEq(totalMigratedOut, 0);
        // No queries yet, no parked pot.
        assertEq(totalQueryFees, 0);
        assertEq(unmigratedSupply, 0);
        // The canonical timeline starts at the genesis.
        assertEq(newMultiverse.canonicalHeir(), GENESIS_UID);
    }

    function test_Constructor_DeploysRepToken() public view {
        LituusRep rep = LituusRep(address(genesisRep));
        assertEq(rep.name(), "Lituus Reputation Token");
        assertEq(rep.symbol(), "REP0");
        // The deployer hands the vault to whoever asked for it: the Multiverse, not the deployer itself.
        assertEq(rep.owner(), address(multiverse));
        assertEq(address(rep.UNDERLYING_TOKEN()), address(underlying));
        assertEq(rep.rate(), multiverse.SCALE());
    }

    function test_Constructor_DeploysRepTokenThroughTheDeployer() public {
        // The deployer's event names the Multiverse as owner, and the vault it announces is the genesis vault.
        address predictedVault = vm.computeCreateAddress(address(vaultDeployer), vm.getNonce(address(vaultDeployer)));
        address predictedMultiverse = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(true, true, true, true, address(vaultDeployer));
        emit LituusRepDeployer.LituusRepDeployed(predictedMultiverse, address(underlying), predictedVault);
        Multiverse newMultiverse = new Multiverse(
            zoltar,
            GENESIS_UID,
            feeCtl,
            queryTokenizerStub,
            vaultDeployer,
            permit2,
            MIGRATION_DURATION,
            REPORTING_PERIOD,
            APPEAL_PERIOD
        );

        (ILituusRep repToken,,,,,,,,,,,,) = newMultiverse.universes(GENESIS_UID);
        assertEq(address(repToken), predictedVault);
        assertEq(LituusRep(predictedVault).owner(), address(newMultiverse));
    }

    function test_VaultDeployer_VaultBelongsToTheCaller() public {
        // Anyone can call the deployer; the vault is owned by the caller and no universe points at it.
        vm.prank(user);
        ILituusRep vault = vaultDeployer.deploy(address(underlying), "Stray", "S", 2 ether);
        assertEq(LituusRep(address(vault)).owner(), user);
        assertEq(LituusRep(address(vault)).rate(), 2 ether);
        assertTrue(address(vault) != address(genesisRep));
    }

    function test_Constructor_Constants() public view {
        assertEq(multiverse.MAX_OUTCOMES(), 254);
        assertEq(multiverse.MIN_OUTCOMES(), 2);
        assertEq(multiverse.UNRESOLVED(), 0);
        assertEq(multiverse.INVALID(), type(uint256).max);
        assertEq(multiverse.APPEAL_PERIOD(), 1 days);
        assertEq(multiverse.REPORTING_PERIOD(), 3 days);
        assertEq(multiverse.MIGRATION_DURATION(), 30 days);
        assertEq(multiverse.BURN_DIVIDER(), 5);
    }
}
