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
        uint8 forkState;
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
        ILituusRep repToken = new LituusRep(address(this), address(initialZoltarRepToken), "Lituus Reputation Token", "REP0");

        Universe memory genesisUniverse;
        genesisUniverse.favoriteChild = 0;
        genesisUniverse.parent = 0;
        genesisUniverse.repToken = repToken;
        genesisUniverse.forkState = 0;
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
