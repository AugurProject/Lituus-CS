// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IZoltar, IZoltarQuestionData } from "../interfaces/IZoltar.sol";
import { IReputationToken } from "../interfaces/IReputationToken.sol";
import { MockERC20 } from "./MockERC20.sol";

contract MockZoltar is IZoltar {
    uint256 constant FORK_THRESHOLD_DIVISOR = 50; // 2% of total supply atm
    // Reference Zoltar's forkBurnDivisor (its minimum): the fork initiator's whole threshold is
    // burned, and all but this fraction of it is credited back to their migration balance. The
    // net burn is threshold / FORK_BURN_DIVISOR = 0.4% of the supply atm.
    uint256 public constant FORK_BURN_DIVISOR = 5;

    // mock accessors mirror the interface's lowercase getter names, so keep the non-standard casing
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IReputationToken public immutable repToken;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IZoltarQuestionData public immutable zoltarQuestionData;

    // Per-universe REP tokens: the genesis is registered at construction, children by deployChild.
    // No entry (address 0) means the universe does not exist — same signal as real Zoltar.
    mapping(uint248 universeId => IReputationToken) public childRepTokens;
    // Theoretical supply per universe, like real Zoltar: the genesis is snapshotted from the REP token
    // at construction (genesis REP is never minted afterwards), a child from its parent's
    // childSupplySnapshot at deployChild; every burn in a universe lowers it.
    mapping(uint248 universeId => uint256) public universeTheoreticalSupplies;
    // Set at forkUniverse: the universe's post-burn theoretical supply plus the initiator's
    // migration credit — the theoretical supply every child of this universe is deployed with
    // (reference Zoltar's childUniverseTheoreticalSupplySnapshots). The initiator's uncredited
    // haircut is permanently absent from every child.
    mapping(uint248 universeId => uint256) public childSupplySnapshots;
    // Fork start time per universe; zero means not forking.
    mapping(uint248 universeId => uint256) public forkTimes;
    mapping(uint248 universeId => uint256) public forkQuestionIds;
    mapping(uint248 universeId => uint248) public parentUniverseIds;
    mapping(uint248 universeId => uint256) public forkingOutcomeIndexes;
    // Caller-keyed migration balances per parent universe, credited against parent REP burned here:
    // forkUniverse credits the initiator's threshold net of the burn haircut, addRepToMigrationBalance
    // credits 1:1.
    mapping(address holder => mapping(uint248 universeId => uint256)) public migrationBalances;
    // Cumulative amount split per child outcome, capped by the holder's persistent balance.
    mapping(address holder => mapping(uint248 universeId => mapping(uint256 outcomeIndex => uint256))) public
        splitPerChild;

    error ChildNotDeployed();
    error ChildAlreadyDeployed();
    error AlreadyForking();
    error InsufficientMigrationBalance();
    error UniverseNotForked();
    error QuestionDoesNotExist();
    error UniverseDoesNotExist();
    error InsufficientRepForFork();
    error ZeroGenesisSupply();

    /// @dev The genesis REP supply must already exist: it is snapshotted here, like real Zoltar reads
    ///      REPv2's theoretical supply once at construction.
    constructor(IReputationToken repToken_, IZoltarQuestionData zoltarQuestionData_, uint248 genesisUniverseId_) {
        uint256 genesisSupply = repToken_.totalSupply();
        if (genesisSupply == 0) revert ZeroGenesisSupply();
        repToken = repToken_;
        zoltarQuestionData = zoltarQuestionData_;
        childRepTokens[genesisUniverseId_] = repToken_;
        universeTheoreticalSupplies[genesisUniverseId_] = genesisSupply;
    }

    function getChildUniverseId(uint248 universeId, uint256 outcomeIndex) public pure returns (uint248) {
        return uint248(uint256(keccak256(abi.encode(universeId, outcomeIndex))));
    }

    /// @dev Address 0 = the universe is not deployed (real-Zoltar signal; no fallback).
    function getRepToken(uint248 universeId) public view returns (IReputationToken) {
        return childRepTokens[universeId];
    }

    /// @dev Zero for a universe that does not exist, like real Zoltar.
    function getUniverseTheoreticalSupply(uint248 universeId) public view returns (uint256) {
        return universeTheoreticalSupplies[universeId];
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
        u.forkingOutcomeIndex = forkingOutcomeIndexes[universeId];
        u.reputationToken = getRepToken(universeId);
        u.parentUniverseId = parentUniverseIds[universeId];
    }

    /// @notice Forks an unforked universe, like real Zoltar: the caller must hold the universe's
    ///         fork threshold in its REP; the whole threshold is burned from them and credited to
    ///         their migration balance net of the burn haircut (threshold / FORK_BURN_DIVISOR).
    /// @dev Fork-once per universe: a second fork reverts instead of silently overwriting the
    ///      in-progress one. The question must exist (real Zoltar also requires it to have ended; not
    ///      modelled here). The universe's theoretical supply drops by the full threshold, and the
    ///      children's supply is snapshotted as that plus the migration credit.
    function forkUniverse(uint248 universeId, uint256 questionId) external {
        if (forkTimes[universeId] != 0) revert AlreadyForking();
        if (zoltarQuestionData.questionCreatedTimestamp(questionId) == 0) revert QuestionDoesNotExist();
        IReputationToken token = childRepTokens[universeId];
        if (address(token) == address(0)) revert UniverseDoesNotExist();
        uint256 threshold = getForkThreshold(universeId);
        if (token.balanceOf(msg.sender) < threshold) revert InsufficientRepForFork();

        forkTimes[universeId] = block.timestamp;
        forkQuestionIds[universeId] = questionId;

        token.burn(msg.sender, threshold);
        universeTheoreticalSupplies[universeId] -= threshold;
        uint256 migrationCredit = threshold - threshold / FORK_BURN_DIVISOR;
        migrationBalances[msg.sender][universeId] += migrationCredit;
        childSupplySnapshots[universeId] = universeTheoreticalSupplies[universeId] + migrationCredit;
    }

    /// @dev Reverts if the child already exists, like real Zoltar: callers must check the child's
    ///      rep token first. The child's theoretical supply is the parent's fork-time snapshot. No malformed-
    ///      answer check here (real Zoltar has one): Lituus forks still key INVALID as max-uint until the
    ///      labels/mapping phase, and the Multiverse enforces Zoltar's rule for mirrored forks itself.
    function deployChild(uint248 universeId, uint256 outcomeIndex) external {
        if (forkTimes[universeId] == 0) revert UniverseNotForked();
        uint248 childUniverseId = getChildUniverseId(universeId, outcomeIndex);
        if (address(childRepTokens[childUniverseId]) != address(0)) revert ChildAlreadyDeployed();
        childRepTokens[childUniverseId] = new MockERC20("Child Reputation", "CREP");
        parentUniverseIds[childUniverseId] = universeId;
        forkingOutcomeIndexes[childUniverseId] = outcomeIndex;
        forkQuestionIds[childUniverseId] = forkQuestionIds[universeId];
        universeTheoreticalSupplies[childUniverseId] = childSupplySnapshots[universeId];
    }

    /// @dev Burns the caller's REP in a forked universe and credits it 1:1 to their migration balance,
    ///      like real Zoltar. The universe's theoretical supply drops by the amount.
    function addRepToMigrationBalance(uint248 universeId, uint256 amount) external {
        if (forkTimes[universeId] == 0) revert UniverseNotForked();
        childRepTokens[universeId].burn(msg.sender, amount);
        universeTheoreticalSupplies[universeId] -= amount;
        migrationBalances[msg.sender][universeId] += amount;
    }

    /// @dev Mints the child's mock REP to the caller 1:1 against their persistent migration
    ///      balance: the per-child cumulative draw may not exceed the balance, but the balance is
    ///      never decremented — duplication across mutually exclusive child worlds is the design.
    function splitMigrationRep(uint248 universeId, uint256 amount, uint256 outcomeIndex) external {
        uint256 spent = splitPerChild[msg.sender][universeId][outcomeIndex] + amount;
        if (spent > migrationBalances[msg.sender][universeId]) revert InsufficientMigrationBalance();
        splitPerChild[msg.sender][universeId][outcomeIndex] = spent;
        uint248 childUniverseId = getChildUniverseId(universeId, outcomeIndex);
        IReputationToken childToken = childRepTokens[childUniverseId];
        if (address(childToken) == address(0)) revert ChildNotDeployed();
        MockERC20(address(childToken)).mint(msg.sender, amount);
    }

    function getMigrationRepBalance(address holder, uint248 universeId) external view returns (uint256) {
        return migrationBalances[holder][universeId];
    }
}
