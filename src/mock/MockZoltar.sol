// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IZoltar, IZoltarQuestionData } from "../interfaces/IZoltar.sol";
import { IReputationToken } from "../interfaces/IReputationToken.sol";
import { MockERC20 } from "./MockERC20.sol";

contract MockZoltar is IZoltar {
    uint256 constant FORK_THRESHOLD_DIVISOR = 20; // 5% of total supply atm
    // Each fork level's theoretical supply decays to 95% of its parent's, mirroring the reference
    // Zoltar's threshold-burn decay.
    uint256 constant CHILD_SUPPLY_NUMERATOR = 19;
    uint256 constant CHILD_SUPPLY_DENOMINATOR = 20;

    // mock accessors mirror the interface's lowercase getter names, so keep the non-standard casing
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IReputationToken public immutable repToken;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IZoltarQuestionData public immutable zoltarQuestionData;

    // Per-universe REP tokens: the genesis is registered at construction, children by deployChild.
    // No entry (address 0) means the universe does not exist — same signal as real Zoltar.
    mapping(uint248 universeId => IReputationToken) public childRepTokens;
    // Theoretical supply snapshotted at deployChild (95% of the parent's). Zero means genesis
    // fallback: the live total supply of the shared repToken.
    mapping(uint248 universeId => uint256) public childTheoreticalSupply;
    // Fork start time per universe; zero means not forking.
    mapping(uint248 universeId => uint256) public forkTimes;
    mapping(uint248 universeId => uint256) public forkQuestionIds;
    // Caller-keyed migration balances per parent universe (credit-only stub: the parent REP is not
    // actually locked/burned here).
    mapping(address holder => mapping(uint248 universeId => uint256)) public migrationBalances;

    error ChildNotDeployed();
    error ChildAlreadyDeployed();
    error AlreadyForking();
    error InsufficientMigrationBalance();
    error UniverseNotForked();

    constructor(IReputationToken repToken_, IZoltarQuestionData zoltarQuestionData_, uint248 genesisUniverseId_) {
        repToken = repToken_;
        zoltarQuestionData = zoltarQuestionData_;
        childRepTokens[genesisUniverseId_] = repToken_;
    }

    function getChildUniverseId(uint248 universeId, uint256 outcomeIndex) public pure returns (uint248) {
        return uint248(uint256(keccak256(abi.encode(universeId, outcomeIndex))));
    }

    /// @dev Address 0 = the universe is not deployed (real-Zoltar signal; no fallback).
    function getRepToken(uint248 universeId) public view returns (IReputationToken) {
        return childRepTokens[universeId];
    }

    function getUniverseTheoreticalSupply(uint248 universeId) public view returns (uint256) {
        uint256 supply = childTheoreticalSupply[universeId];
        return supply == 0 ? repToken.totalSupply() : supply;
    }

    function getForkThreshold(uint248 universeId) public view returns (uint256) {
        return getUniverseTheoreticalSupply(universeId) / FORK_THRESHOLD_DIVISOR;
    }

    /// @notice The universe's fork start time; zero means the universe has not forked.
    function getForkTime(uint248 universeId) external view returns (uint256) {
        return forkTimes[universeId];
    }

    function universes(uint248 universeId) external view returns (Universe memory u) {
        u.forkTime = forkTimes[universeId];
        u.forkQuestionId = forkQuestionIds[universeId];
        u.forkingOutcomeIndex = 0;
        u.reputationToken = getRepToken(universeId);
        u.parentUniverseId = 0;
    }

    /// @dev Fork-once per universe, like real Zoltar: a second fork reverts instead of silently
    ///      overwriting the in-progress one.
    function forkUniverse(uint248 universeId, uint256 questionId) external {
        if (forkTimes[universeId] != 0) revert AlreadyForking();
        forkTimes[universeId] = block.timestamp;
        forkQuestionIds[universeId] = questionId;
    }

    /// @dev Reverts if the child already exists, like real Zoltar: callers must check the child's
    ///      rep token first. The child's theoretical supply snapshots to 95% of the parent's.
    function deployChild(uint248 universeId, uint256 outcomeIndex) external {
        if (forkTimes[universeId] == 0) revert UniverseNotForked();
        uint248 childUniverseId = getChildUniverseId(universeId, outcomeIndex);
        if (address(childRepTokens[childUniverseId]) != address(0)) revert ChildAlreadyDeployed();
        childRepTokens[childUniverseId] = new MockERC20("Child Reputation", "CREP");
        childTheoreticalSupply[childUniverseId] =
            getUniverseTheoreticalSupply(universeId) * CHILD_SUPPLY_NUMERATOR / CHILD_SUPPLY_DENOMINATOR;
    }

    /// @dev Credit-only stub: real Zoltar burns/locks the parent REP; the mock just records the
    ///      balance so splitMigrationRep can mint against it.
    function addRepToMigrationBalance(uint248 universeId, uint256 amount) external {
        migrationBalances[msg.sender][universeId] += amount;
    }

    /// @dev Mints the child's mock REP to the caller against their migration balance, 1:1.
    function splitMigrationRep(uint248 universeId, uint256 amount, uint256 outcomeIndex) external {
        if (migrationBalances[msg.sender][universeId] < amount) revert InsufficientMigrationBalance();
        migrationBalances[msg.sender][universeId] -= amount;
        uint248 childUniverseId = getChildUniverseId(universeId, outcomeIndex);
        IReputationToken childToken = childRepTokens[childUniverseId];
        if (address(childToken) == address(0)) revert ChildNotDeployed();
        MockERC20(address(childToken)).mint(msg.sender, amount);
    }

    function getMigrationRepBalance(address holder, uint248 universeId) external view returns (uint256) {
        return migrationBalances[holder][universeId];
    }
}
