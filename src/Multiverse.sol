// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IZoltar } from "./interfaces/IZoltar.sol";
import { ILituusRep } from "./interfaces/ILituusRep.sol";
import { LituusRep } from "./LituusRep.sol";
import { IReputationToken } from "./interfaces/IReputationToken.sol";
import { IQueryFeeController } from "./interfaces/IQueryFeeController.sol";

contract Multiverse {
    using SafeERC20 for IERC20;
    using SafeERC20 for ILituusRep;

    uint16 public constant MAX_OUTCOMES = 253; //number of outcomes for a query
    uint16 public constant MAX_FORK_OUTCOMES = 2; //number of outcomes for a forking query
    uint16 public constant UNRESOLVED = 255; // Not reported in time.
    uint16 public constant INVALID = 254; // an invalid outcome value used for reporting an invalid fork outcome during
    // fork resolution. It is outside the valid outcome range [0, MAX_OUTCOMES-1]
    uint16 public constant NO_REPORT = 0; // the starting value for outcome is NO_REPORT.

    enum ForkState {
        NotForking, // 0 - default; universe is operating normally
        AwaitingChildren, // 1 - system frozen, waiting for forkUniverse() to be called
        InitialMigration, // 2 - forking in progress; REP holders migrate to child universes
        SupplyRestoration1, // 3 - SR attempt 1
        SupplyRestoration2, // 4 - SR attempt 2
        SupplyRestoration3, // 5 - SR attempt 3
        PostFork, // 6 - fork finalized
        Forming // 7 - child universe still being formed
    }

    struct Stake {
        address owner;
        uint48 claim;
        uint48 time;
        uint256 amount;
    }

    struct Query {
        uint48 createTime;
        uint16 numberOfOutcomes;
        uint248 originUniverse;
        uint256 fee;
        string question;
        bytes32[] resolvedUniverses;
    }

    struct Outcome {
        uint16 outcome;
        uint256 totalStake;
        Stake[] stake;
    }

    struct Universe {
        ILituusRep repToken;
        ForkState forkState;
        uint248 parent;
        uint248 favoriteChild;
        uint248 heir;
        bytes32 history;
        uint256 forkQuery;
        uint256 supplyBeforeFork;
        address queryTokenizer;
    }

    mapping(uint248 => Universe) public universes;
    mapping(uint256 => Query) public queries;
    mapping(uint248 => mapping(uint256 => Outcome)) outcomes; // universeId => queryId => Outcome

    uint256 public queryCount;

    IZoltar public immutable ZOLTAR;

    event QueryCreated(uint256 indexed queryId, uint248 indexed universeId, string question, uint16 numberOfOutcomes);

    error ZeroAddress();
    error InvalidUniverse();
    error UniverseForking();
    error InvalidNumberOfOutcomes();

    IQueryFeeController public immutable QUERY_FEE_CONTROLLER;

    constructor(IZoltar _zoltar, uint248 _initialZoltarUniverseId, IQueryFeeController _queryFeeController) {
        ZOLTAR = _zoltar;
        if (address(ZOLTAR) == address(0)) revert ZeroAddress();
        QUERY_FEE_CONTROLLER = _queryFeeController;
        if (address(QUERY_FEE_CONTROLLER) == address(0)) revert ZeroAddress();

        // get the rep token address from the initial universe in Zoltar
        IReputationToken initialZoltarRepToken = ZOLTAR.getRepToken(_initialZoltarUniverseId);
        // deploy a Lituus REP token that wraps the Zoltar REP token
        // token symbol will use universe.history as a suffix. Genesis universe will have symbol "REP0"
        // TODO: Discuss the format of the suffix if the forks are for binary queries.
        ILituusRep repToken =
            new LituusRep(address(this), address(initialZoltarRepToken), "Lituus Reputation Token", "REP0");

        Universe storage genesisUniverse = universes[0];
        genesisUniverse.favoriteChild = 0;
        genesisUniverse.parent = 0;
        genesisUniverse.repToken = repToken;
        genesisUniverse.forkState = ForkState.NotForking;
        genesisUniverse.heir = 0;
        genesisUniverse.history = 0;
        genesisUniverse.forkQuery = 0;
        genesisUniverse.supplyBeforeFork = repToken.totalSupply(); // TODO: what should it be?
        genesisUniverse.queryTokenizer = address(0);
    }

    function wrap(uint248 universeId, uint256 amount) external {
        // TODO: check universe status
        universes[universeId].repToken.wrap(msg.sender, amount);
    }

    function unwrap(uint248 universeId, uint256 amount) external {
        // TODO: check universe status
        universes[universeId].repToken.unwrap(msg.sender, amount);
    }

    // Main functions

    function createQuery(uint248 universeId, string calldata question, uint16 numberOfOutcomes) external {
        Universe storage universe = universes[universeId];
        ILituusRep repToken = universe.repToken;
        if (address(repToken) == address(0)) revert InvalidUniverse();
        // Forward the transaction to the heir
        uint248 heirId = universe.heir;
        if (heirId != universeId) {
            universe = universes[heirId];
            repToken = universe.repToken;
            if (address(repToken) == address(0)) revert InvalidUniverse();
        }
        // TODO: double check the allowed states
        // Query creation is allowed during a fork in child universes
        // but not in the parent universe that is forking.
        ForkState forkState = universe.forkState;
        if (
            forkState == ForkState.InitialMigration || forkState == ForkState.SupplyRestoration1
                || forkState == ForkState.SupplyRestoration2 || forkState == ForkState.SupplyRestoration3
                || forkState == ForkState.PostFork
        ) {
            revert UniverseForking();
        }
        // Validate the question and number of outcomes
        if (numberOfOutcomes <= 2) revert InvalidNumberOfOutcomes();
        if (numberOfOutcomes > MAX_OUTCOMES) revert InvalidNumberOfOutcomes();

        // Get the fee amount from the query fee controller
        uint256 fee = QUERY_FEE_CONTROLLER.getQueryFee(universeId);
        // Transfer the query fee amount of REP token
        // TODO: permit? permit2?
        repToken.safeTransferFrom(msg.sender, address(this), fee);
        // Create a global query record

        Query storage query = queries[queryCount];
        query.createTime = uint48(block.timestamp);
        query.numberOfOutcomes = numberOfOutcomes;
        query.originUniverse = universeId;
        query.fee = fee;
        query.question = question;

        // A universe-specific outcome record will start with NO_REPORT
        // The record will be populated when the first report comes in

        // Emit an event
        emit QueryCreated(queryCount, universeId, question, numberOfOutcomes);

        queryCount++;
    }

    function getOutcome(uint248 universeId, uint256 queryId) external view returns (uint16) {
        return outcomes[universeId][queryId].outcome;
    }

    function getOutcomeData(uint248 universeId, uint256 queryId) external view returns (Outcome memory) {
        return outcomes[universeId][queryId];
    }
}
