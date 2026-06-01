// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IZoltar } from "./interfaces/IZoltar.sol";
import { ILituusRep } from "./interfaces/ILituusRep.sol";
import { LituusRep } from "./LituusRep.sol";
import { IReputationToken } from "./interfaces/IReputationToken.sol";

contract Multiverse {

    using SafeERC20 for IERC20;

    uint public constant MAX_OUTCOMES = 255;		//number of outcomes for a query
    uint public constant MAX_FORK_OUTCOMES = 2;		//number of outcomes for a forking query
	uint public constant UNRESOLVED	= MAX_OUTCOMES;	//the starting value for outcome is UNRESOLVED. Outcome 0 is the first, outcome (MAX_OUTCOMES-1) is the last.
	uint public constant NO_REPORT = MAX_OUTCOMES;	//the starting value for lastReport is NO_REPORT. 

    enum ForkState {
        NotForking,         // 0 - default; universe is operating normally
        AwaitingChildren,   // 1 - system frozen, waiting for forkUniverse() to be called
        InitialMigration,   // 2 - forking in progress; REP holders migrate to child universes
        SupplyRestoration1, // 3 - SR attempt 1
        SupplyRestoration2, // 4 - SR attempt 2
        SupplyRestoration3, // 5 - SR attempt 3
        PostFork,           // 6 - fork finalized
        Forming             // 7 - child universe still being formed
    }

    struct Stake
	{
		address owner;
		uint48 claim;
		uint48 time;	
		uint256 amount;
	}

    struct Query
    {
        uint48 createTime;
        uint16 numberOfOutcomes;
        uint64 originUniverse;
        uint256 fee;
        string question;
        bytes32[] resolvedUniverses;
    }

    struct Outcome
    {
        uint16 outcome;
        uint256 totalStake;
        Stake[] stake;
    }

    struct Universe
    {
        ILituusRep repToken;
        ForkState forkState;
        uint64 parent;
        uint64 favoriteChild;
        uint64 heir;
        bytes32[] history;
        uint256 forkQuery;
        uint256 supplyBeforeFork;
        address queryTokenizer;
    }

    mapping(uint248 => Universe) public universes;
    mapping(uint256 => Query) public queries;
    mapping(uint248 => mapping(uint256 => Outcome)) outcomes; // universeId => queryId => Outcome

    uint256 public queryCount;

    IZoltar public immutable ZOLTAR;

    error ZeroAddress();

    constructor(IZoltar _zoltar, uint248 _initialZoltarUniverseId) {
        ZOLTAR = _zoltar;
        if (address(ZOLTAR) == address(0)) revert ZeroAddress();

        // get the rep token address from the initial universe in Zoltar
        IReputationToken initialZoltarRepToken = ZOLTAR.getRepToken(_initialZoltarUniverseId);
        // deploy a Lituus REP token that wraps the Zoltar REP token
        // token symbol will use universe.history as a suffix. Genesis universe will have symbol "REP0"
        // TODO: Discuss the format of the suffix if the forks are for binary queries.
        ILituusRep repToken = new LituusRep(address(this), address(initialZoltarRepToken), "Lituus Reputation Token", "REP0");

        Universe memory genesisUniverse;
        genesisUniverse.favoriteChild = 0;
        genesisUniverse.parent = 0;
        genesisUniverse.repToken = repToken;
        genesisUniverse.forkState = ForkState.NotForking;
        genesisUniverse.heir = 0;
        genesisUniverse.history = new bytes32[](0);
        genesisUniverse.forkQuery = 0;
        genesisUniverse.supplyBeforeFork = repToken.totalSupply(); // TODO: what should it be?
        genesisUniverse.queryTokenizer = address(0);
        universes[0] = genesisUniverse;
    }

    function wrap(uint248 universeId, uint256 amount) external {
        // TODO: check universe status
        universes[universeId].repToken.wrap(msg.sender, amount);
    }

    function unwrap(uint248 universeId, uint256 amount) external {
        // TODO: check universe status
        universes[universeId].repToken.unwrap(msg.sender, amount);
    }
}
