// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { MultiverseDeployFixture } from "../unit/Multiverse.fixtures.sol";

/// @notice Shared fixtures for the Multiverse fuzz test suites: the deploy layer plus the fuzz
///         actors.
/// @dev Inherits the deployment from MultiverseDeployFixture instead of duplicating it (single
///      deploy definition, deterministic START_TIME clock, controller hooks available). Adds the
///      fuzz-specific actors on top.
abstract contract MultiverseFuzzFixtures is MultiverseDeployFixture {
    address internal reporter = makeAddr("reporter");
    // The resolver is deliberately never funded: resolving costs nothing, so its balance isolates
    // exactly what resolve() pays the caller.
    address internal resolver = makeAddr("resolver");

    function setUp() public virtual override {
        super.setUp();

        _fundWithRep(user, USER_REP_BALANCE);
        _fundWithRep(reporter, USER_REP_BALANCE);
    }

    /// @dev Creates a default 3-outcome query as `user` and returns its id.
    function _createQuery() internal returns (uint256 queryId) {
        queryId = multiverse.queryCount();
        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", 3);
    }

    /// @dev Builds an escalation ladder of `rounds` same-block stakes on a fresh query: outcomes
    ///      alternate 1/2 and reporters alternate user/reporter, so ownership and winning stakes
    ///      vary with parity (mirrors testFuzz_Report_EscalationDoubles's loop). Same-block
    ///      escalation is legal since consecutive outcomes differ.
    /// @return queryId The id of the reported query.
    function _buildLadder(uint256 rounds) internal returns (uint256 queryId) {
        queryId = _createQuery();
        for (uint256 i = 0; i < rounds; i++) {
            vm.prank(i % 2 == 0 ? user : reporter);
            multiverse.report(GENESIS_UID, queryId, i % 2 == 0 ? 1 : 2);
        }
    }
}
