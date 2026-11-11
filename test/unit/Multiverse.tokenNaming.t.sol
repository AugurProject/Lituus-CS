// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { QueryTokenizerFixtures } from "./QueryTokenizer.fixtures.sol";

/// @notice Per-universe token names follow Zoltar's REP numbering: the wREP vault and the query token of a
///         universe carry the repNumber of that universe's Zoltar REP ("REP<n>" -> "wREP<n>" / "QT<n>"), and the
///         genesis, whose REPv2 has no number, takes 0.
contract MultiverseTokenNamingTest is QueryTokenizerFixtures {
    function _assertMetadata(address token, string memory expectedName, string memory expectedSymbol) internal view {
        assertEq(IERC20Metadata(token).name(), expectedName);
        assertEq(IERC20Metadata(token).symbol(), expectedSymbol);
    }

    function _zoltarSymbol(uint248 universeId) internal view returns (string memory) {
        return IERC20Metadata(address(zoltar.getRepToken(universeId))).symbol();
    }

    /* ================================================ GENESIS ================================================= */

    function test_GenesisVault_NumberZero() public view {
        _assertMetadata(address(genesisRep), "Lituus Reputation Token 0", "wREP0");
    }

    /* ============================================= CHILD VAULTS =============================================== */

    /// @dev The number is Zoltar's deployment order, not the outcome: B spawned first is REP1.
    function test_ChildVaults_NamedInZoltarDeployOrder() public {
        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_B);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        uint248 childA = _childId(GENESIS_UID, OUTCOME_A);
        uint248 childB = _childId(GENESIS_UID, OUTCOME_B);

        _assertMetadata(address(multiverse.repTokenOf(childB)), "Lituus Reputation Token 1", "wREP1");
        _assertMetadata(address(multiverse.repTokenOf(childA)), "Lituus Reputation Token 2", "wREP2");
        assertEq(
            IERC20Metadata(address(multiverse.repTokenOf(childA))).symbol(), string.concat("w", _zoltarSymbol(childA))
        );
    }

    /// @dev A Zoltar child deployed natively before Lituus spawns it keeps the number Zoltar gave it, and the
    ///      next Lituus spawn continues Zoltar's count.
    function test_ChildVault_NativeZoltarChildKeepsItsNumber() public {
        _forkGenesis();
        zoltar.deployChild(GENESIS_UID, OUTCOME_C);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_C);

        _assertMetadata(
            address(multiverse.repTokenOf(_childId(GENESIS_UID, OUTCOME_C))), "Lituus Reputation Token 1", "wREP1"
        );
        _assertMetadata(
            address(multiverse.repTokenOf(_childId(GENESIS_UID, OUTCOME_A))), "Lituus Reputation Token 2", "wREP2"
        );
    }

    /// @dev Zoltar numbers children across the whole tree, so a grandchild continues after its parent's siblings.
    function test_GrandchildVault_NumberingIsTreeWide() public {
        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_B);
        uint248 childA = _childId(GENESIS_UID, OUTCOME_A);

        // Fork child A on a query of its own, paid and escalated with genesis wREP migrated into it.
        ILituusRep childRep = multiverse.repTokenOf(childA);
        vm.startPrank(user);
        multiverse.migrate(GENESIS_UID, OUTCOME_A, 200 ether);
        childRep.approve(address(multiverse), type(uint256).max);
        uint256 queryId = multiverse.queryCount();
        multiverse.createQuery(childA, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        vm.stopPrank();
        _escalateToFork(childA, queryId, user, user);
        multiverse.spawnChildUniverse(childA, OUTCOME_A);

        _assertMetadata(
            address(multiverse.repTokenOf(_childId(childA, OUTCOME_A))), "Lituus Reputation Token 3", "wREP3"
        );
    }

    /// @dev If a Zoltar child was deployed before the parent's sibling, its number is smaller than the sibling's.
    function test_GrandchildVault_NumberingIsIncremental() public {
        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        uint248 childA = _childId(GENESIS_UID, OUTCOME_A);
        _assertMetadata(
            address(multiverse.repTokenOf(_childId(GENESIS_UID, OUTCOME_A))), "Lituus Reputation Token 1", "wREP1"
        );

        // Fork child A on a query of its own, paid and escalated with genesis wREP migrated into it.
        ILituusRep childRep = multiverse.repTokenOf(childA);
        vm.startPrank(user);
        multiverse.migrate(GENESIS_UID, OUTCOME_A, 200 ether);
        childRep.approve(address(multiverse), type(uint256).max);
        uint256 queryId = multiverse.queryCount();
        multiverse.createQuery(childA, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        vm.stopPrank();
        _escalateToFork(childA, queryId, user, user);
        // Grandchild
        multiverse.spawnChildUniverse(childA, OUTCOME_A);
        _assertMetadata(
            address(multiverse.repTokenOf(_childId(childA, OUTCOME_A))), "Lituus Reputation Token 2", "wREP2"
        );

        // Sibling of child A, spawned after the grandchild, takes the next number.
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_B);
        _assertMetadata(
            address(multiverse.repTokenOf(_childId(GENESIS_UID, OUTCOME_B))), "Lituus Reputation Token 3", "wREP3"
        );
    }

    /* ========================================== CHILD QUERY TOKENS ============================================ */

    /// @dev The child's query token, deployed on first migration, carries the same number as the child's vault.
    function test_ChildQueryToken_MatchesChildVaultNumber() public {
        _mintTokens(user, 2);
        _forkGenesis();
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_B);
        multiverse.spawnChildUniverse(GENESIS_UID, OUTCOME_A);
        uint248 childA = _childId(GENESIS_UID, OUTCOME_A);

        vm.prank(user);
        tokenizer.migrate(GENESIS_UID, OUTCOME_A, 1);

        _assertMetadata(address(tokenizer.token(childA)), "Lituus Query Token 2", "QT2");
        assertEq(IERC20Metadata(address(multiverse.repTokenOf(childA))).symbol(), "wREP2");
    }
}
