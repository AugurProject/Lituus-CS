// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IZoltar, IZoltarQuestionData } from "../interfaces/IZoltar.sol";
import { ILituusRep } from "../interfaces/ILituusRep.sol";
import { IReputationToken } from "../interfaces/IReputationToken.sol";
import { ITokenDeployer } from "../interfaces/ITokenDeployer.sol";
import { IQueryTokenizer } from "../interfaces/IQueryTokenizer.sol";
import { Multiverse } from "../Multiverse.sol";
import { MultiverseHelpers } from "./MultiverseHelpers.sol";
import { LituusRepMath } from "./LituusRepMath.sol";

/**
 * @title ForkLib
 * @notice The fork-time half of the Multiverse: forking a universe on a query, mirroring a native Zoltar fork,
 *         spawning children, the migration lanes and advancing a fork out of Migration.
 * @dev An external library, reached only by DELEGATECALL from the Multiverse's entry points: it runs on the
 *      Multiverse's storage, address and msg.sender, and has no storage of its own. It exists to keep the
 *      Multiverse under the EIP-170 size limit. Per-query paths reach it on two branches only: report() when the
 *      report triggers a fork, and resolve() when it mirrors a native Zoltar fork. Only the external functions are
 *      reachable from the Multiverse — everything else is private, so no fork code is ever compiled back into it.
 *      The Multiverse's mappings come in as storage arguments. A library cannot hold immutables, so each
 *      function takes the Multiverse immutables it uses as arguments, named after them (ZOLTAR -> zoltar,
 *      MIGRATION_DURATION -> migrationDuration, ...). The plain state variables stay with the Multiverse: it
 *      advances queryCount before a mirror and writes canonicalHeir from advanceForkState's return value. Types,
 *      events and errors stay declared in the Multiverse; the shared constants live in MultiverseHelpers.
 */
library ForkLib {
    using SafeERC20 for IERC20;
    using SafeERC20 for ILituusRep;

    /* ============================================ FORKING FUNCTIONS ============================================ */
    /// @notice Forks a universe on a query whose escalation reached the fork threshold.
    /// @dev Zero eager children: the fork question mirrors the query's own outcome set and every child
    ///      is spawned lazily via spawnChildUniverse. The Zoltar question submits the raw Lituus
    ///      question string with numbered outcome labels — real-Zoltar label ordering (hash-descending)
    ///      is a later phase; against the mock the labels are unchecked.
    function forkLituusUniverse(
        mapping(uint248 universeId => Multiverse.Universe) storage universes,
        mapping(uint256 queryId => Multiverse.Query) storage queries,
        mapping(uint248 universeId => mapping(uint256 queryId => Multiverse.QueryResolution)) storage queryResolutions,
        IZoltar zoltar,
        IZoltarQuestionData zoltarQuestionData,
        IQueryTokenizer queryTokenizer,
        uint248 universeId,
        uint256 queryId
    ) external {
        Multiverse.Universe storage universe = universes[universeId];

        // The Zoltar counterpart may have forked natively, in this case this call should revert
        // and Zoltar fork should be mirrored. The current query will be refunded as the rest of
        // the queries in this universe, and the reporting can start over in a child immediately.
        if (zoltar.getForkTime(universeId) != 0) revert Multiverse.ZoltarUniverseAlreadyForking();

        Multiverse.Query storage query = queries[queryId];

        IZoltarQuestionData.QuestionData memory questionData;
        questionData.title = _createForkQuestionString(query);
        questionData.description = "";
        questionData.startTime = block.timestamp - 1 days;
        // in Zoltar: require(block.timestamp >= endTime, 'Question has not ended');
        questionData.endTime = block.timestamp - 1 days;
        questionData.numTicks = 0;
        questionData.displayValueMin = 0;
        questionData.displayValueMax = 0;
        questionData.answerUnit = "";

        // Placeholder labels — the mock ignores them (it need not even match the outcome count).
        // TODO: The real label set (one per Lituus outcome plus INVALID, hash-ordered) is to
        // be implemented later.
        string[] memory outcomes = new string[](2);
        outcomes[0] = "1";
        outcomes[1] = "2";

        uint256 zoltarQueryId = zoltarQuestionData.createQuestion(questionData, outcomes);
        if (zoltarQueryId == 0) revert Multiverse.ZoltarQueryCreationFailed();

        // The forking query's fee and tips stay in the aggregates. Each child takes the fee out of the fee pool it
        // copies at its spawn and pays the share earned to the first reporter of its own outcome (see
        // _fundChildAndPayForkReporter). The tips cap covers the forking query's tips with the open queries' tips, and
        // each child pays them to its reporter out of the tips it carries. The cap runs before the pot is
        // unwrapped, so it is measured against the whole wREP supply and the excess can still be donated in
        // wREP.
        _capCarriedTips(queryTokenizer, universeId, universe);

        // Fork in Zoltar. It burns the fork bond from this contract's REP and credits most of it back to our
        // migration balance, so the whole pot is unwrapped first. The bond is two caps (2% of the supply) and
        // the forking query holds exactly that in its two outcomes at the cap (see Multiverse._capShares), with
        // its fee on top, so the REP in hand always covers it. The threshold is read before the burn lowers the
        // supply it is derived from.
        ILituusRep repToken = universe.repToken;
        uint256 potAssets = repToken.migrateOut(address(this), repToken.balanceOf(address(this)));
        uint256 forkThreshold = zoltar.getForkThreshold(universeId);
        zoltar.forkUniverse(universeId, zoltarQueryId);
        // Nothing was parked before the fork, so the balance is what Zoltar credited back. The rest of the bond
        // is gone for good; it comes off the forking query's losing side when the stakes are paid out in the
        // children (see _forkPayout). Share amounts are bounded by the REP max supply, within uint96.
        uint256 zoltarBurn = forkThreshold - zoltar.getMigrationRepBalance(address(this), universeId);
        // forge-lint: disable-next-line(unsafe-typecast)
        queryResolutions[universeId][queryId].forkBurn = uint96(repToken.convertToSharesUp(zoltarBurn));

        // The Lituus query now has a Zoltar question: the fork question just submitted.
        query.zoltarQuestionId = zoltarQueryId;

        // queryId indexes queries by count, within uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.forkQuery = uint128(queryId);
        universe.isLituusFork = true;
        _enterMigration(zoltar, universeId, universe, queryId, zoltarQueryId, potAssets - forkThreshold, zoltarBurn);
    }

    /**
     * @notice Imports a native Zoltar fork by id: the mirrored fork is a Lituus fork minus the forking-query
     *         payouts. A Lituus query is created for the Zoltar fork question so getOutcome(child, forkQuery)
     *         tells which branch any descendant universe stands on, exactly as for a Lituus fork.
     * @dev The query is Zoltar-defined: numberOfOutcomes stays 0 and zoltarQuestionId is Zoltar's forkQuestionId;
     *      its title, labels and answer validity live in ZoltarQuestionData and are never copied here. Nothing
     *      is read from the question at mirror time, so no Zoltar fork — categorical or scalar — can fail to
     *      mirror. Children spawn lazily through spawnChildUniverse, keyed by Zoltar answer, and each resolves
     *      the mirrored query to its own answer at spawn. No fee: there is nothing to pay out for this query.
     * @param queryId The id the mirrored query is created under. The Multiverse has already advanced its
     * queryCount past it, so the count is never behind while the external calls below run.
     */
    function mirrorZoltarFork(
        mapping(uint248 universeId => Multiverse.Universe) storage universes,
        mapping(uint256 queryId => Multiverse.Query) storage queries,
        mapping(uint248 universeId => mapping(uint256 queryId => Multiverse.QueryResolution)) storage queryResolutions,
        IZoltar zoltar,
        IQueryTokenizer queryTokenizer,
        uint248 universeId,
        uint256 queryId
    ) external {
        Multiverse.Universe storage universe = MultiverseHelpers._checkUniverseState(universes, universeId);
        if (zoltar.getForkTime(universeId) == 0) revert Multiverse.ZoltarUniverseIsNotForking();

        uint256 zoltarQuestionId = zoltar.universes(universeId).forkQuestionId;

        Multiverse.Query storage query = queries[queryId];
        // numberOfOutcomes stays 0 (the outcome set is Zoltar's), question stays empty (the title is Zoltar's),
        // fee stays 0 (nothing is ever paid out for this query).
        query.originUniverse = universeId;
        query.zoltarQuestionId = zoltarQuestionId;
        // The origin's record exists from creation, as for every query. Its outcome stays UNRESOLVED: the
        // forking universe never resolves its own fork question; its children do, each its own way.
        queryResolutions[universeId][queryId].queryCreateTime = uint48(block.timestamp);
        emit Multiverse.QueryCreated(msg.sender, queryId, universeId, "", 0);

        // queryId indexes queries by count, within uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.forkQuery = uint128(queryId);
        // Explicit for clarity: a mirrored fork pays nothing out for its forking query.
        universe.isLituusFork = false;
        // A mirrored fork has no forking Lituus query: every tip in the aggregate is an open query's. Capped
        // before the pot is parked, as in a Lituus fork.
        _capCarriedTips(queryTokenizer, universeId, universe);
        _enterMigration(zoltar, universeId, universe, queryId, zoltarQuestionId, 0, 0);
    }

    /**
     * @notice The state transition shared by both fork kinds — a Lituus escalation fork and a mirrored
     *         native Zoltar fork: the universe enters Migration, its fork clock starts, its whole pot is
     *         parked in the Zoltar migration balance and its vault is unwrap-paused for good.
     * @dev forkQuery and isLituusFork are the caller's to set before this runs (they differ per kind).
     *      forkTime is Lituus time — the tx that forks or mirrors — never Zoltar's own fork time: a late
     *      mirror must still open a full migration window, or the permanent unwrap pause would strand
     *      every holder with the window already closed. (For a Lituus fork the two times coincide.)
     *      `unwrappedAssets` is REP the caller already unwrapped and still holds here (for a Lituus fork, the
     *      pot left after the bond) and `zoltarBurn` what Zoltar kept of the bond; both are zero for a
     *      mirrored fork.
     */
    function _enterMigration(
        IZoltar zoltar,
        uint248 universeId,
        Multiverse.Universe storage universe,
        uint256 queryId,
        uint256 zoltarQuestionId,
        uint256 unwrappedAssets,
        uint256 zoltarBurn
    ) private {
        universe.universeState = Multiverse.UniverseState.Migration;
        universe.forkTime = uint48(block.timestamp);
        _addPotToMigrationBalance(zoltar, universeId, universe, unwrappedAssets, zoltarBurn);
        // Permanent: wrapped capital in a forked universe exits ONLY through the counted Lituus
        // migration lanes (migrate() and migrateStake()) — never by unwrapping to the Zoltar level.
        // No code path ever unpauses a forked universe's vault.
        universe.repToken.setUnwrapPaused(true);
        emit Multiverse.UniverseForked(universeId, queryId, zoltarQuestionId, universe.isLituusFork);
    }

    /**
     * @notice Parks the contract's entire wREP holding of a forking universe in the Zoltar
     *         migration balance: query fees, tips, the forking query's pot, and all other stakes and
     *         unclaimed winnings. Runs once, in the fork tx.
     * @dev `unwrappedAssets` is REP already unwrapped and still held here (the pot left after the fork
     *      bond for a Lituus fork, zero for a mirrored one) and `zoltarBurn` what Zoltar kept of the
     *      bond. From here every path to this value is a "second part" of a migration — minting into
     *      a child universe (fee and tip splits at spawn, the forking query's reward and tips at spawn, stakes
     *      through migrateStake).
     *      Nothing is ever withdrawable on the parent side again. unmigratedSupply records the pot as
     *      it stood before the fork, parked plus burned: stake claims take their principal out of it
     *      at face value, so it has to carry the burned part too. SR max supply = totalMigratedOut +
     *      unmigratedSupply, less the burn kept on the forking query's record.
     */
    function _addPotToMigrationBalance(
        IZoltar zoltar,
        uint248 universeId,
        Multiverse.Universe storage universe,
        uint256 unwrappedAssets,
        uint256 zoltarBurn
    ) private {
        uint256 potShares = universe.repToken.balanceOf(address(this));
        if (potShares > 0) unwrappedAssets += universe.repToken.migrateOut(address(this), potShares);
        if (unwrappedAssets > 0) zoltar.addRepToMigrationBalance(universeId, unwrappedAssets);
        // Nothing was parked before the fork, so the balance is the pot net of the burn.
        // Asset amounts are REP amounts within uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.unmigratedSupply = uint128(zoltar.getMigrationRepBalance(address(this), universeId) + zoltarBurn);
    }

    /**
     * @notice Builds the question text for creating a fork in Zoltar.
     * @dev Placeholder — returns the original question unchanged; Zoltar formatting is TODO.
     * @param query The query being forked on.
     * @return The question string for the Zoltar query.
     */
    function _createForkQuestionString(Multiverse.Query storage query) private view returns (string memory) {
        // TODO: Placeholder for now
        return query.question;
    }

    /**
     * @notice Sets the tips a forking universe's children carry: capped at 0.1% of its wREP supply
     *         (FORK_TIP_CAP_DIVISOR), then rounded down to what a child's vault mints for them. Runs once, in the
     *         fork tx, before the pot is unwrapped.
     * @dev The aggregate it caps is every unpaid tip the universe holds: its open queries' tips and, in a Lituus
     *      fork, the forking query's. One cap covers them all.
     *      Every child copies the carried tips, outside the counted migration lanes, so wREP placed as tips
     *      would otherwise reach every child without choosing a side. The cap bounds that copy. The supply is
     *      the vault's share supply as it stands in the fork tx, the Multiverse's own holdings included: tips are
     *      share amounts, so nothing is converted, and the cap is the same fraction of the wrapped REP at any
     *      rate.
     *      The cap has no floor: the tips a universe inherited are held against its own supply like the tips
     *      placed in it. A universe that forks before its parent's REP has migrated in holds little more in its
     *      vault than its own fee and tip aggregates, and 0.1% of that is next to nothing: nearly all of its
     *      tips are excess (see below). That loss is accepted.
     *      The copy goes through the rate, shares to REP here and REP to shares in the child, and both steps
     *      round down, so a child's vault can mint a wei less than the shares carried. The carried aggregate is
     *      rounded down to that amount here, once, and stored in carriedTips. Every child then draws exactly that
     *      (see _fundChildAndPayForkReporter), and the wei stays in this universe's balance, parked with the pot.
     *      totalTips keeps the aggregate before the cap and the rounding, and every query's tips are cut by
     *      carriedTips / totalTips, rounded down: the forking query's at spawn, an open query's wherever a child
     *      reads them (see Multiverse._carriedTips). The cut tips never add up to more than the carried
     *      aggregate they are paid from: the rounding leaves dust in a child's aggregate, never a shortage.
     *      The excess above the cap is exact. It goes to the universe's query-token pool, which leaves the
     *      universe only through the counted QueryTokenizer.migrate, into one child per token. If the universe
     *      has no query tokens the excess stays in the balance: it is parked with the pot and no child ever
     *      draws it. It is not burned with burnShares: that would raise the rate and hand part of it back to the
     *      fee and tip copies.
     *      The donation is one call to the tokenizer, which both decides and books (see
     *      IQueryTokenizer.donateRep), followed at once by the transfer of what it accepted.
     */
    function _capCarriedTips(IQueryTokenizer queryTokenizer, uint248 universeId, Multiverse.Universe storage universe)
        private
    {
        uint256 tips = universe.totalTips;
        // No unpaid tips: nothing to carry, and carriedTips stays zero.
        if (tips == 0) return;
        ILituusRep repToken = universe.repToken;
        uint256 cap = repToken.totalSupply() / MultiverseHelpers.FORK_TIP_CAP_DIVISOR;
        // What a child's vault mints for the tips under the cap: shares to REP and back at this universe's rate,
        // which is final from here on and is the rate every child's vault starts at.
        uint256 carried = _asChildShares(tips > cap ? cap : tips, repToken.rate());
        // At most the aggregate, within uint128. A zero is what the slot holds already.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (carried != 0) universe.carriedTips = uint128(carried);
        // Carried whole: nothing was cut.
        if (carried == tips) return;

        uint256 donated;
        if (tips > cap) {
            uint256 excess = tips - cap;
            // The tokenizer is asked once. It takes the excess only if the universe has query tokens to carry
            // it out, and on a yes it has already credited its pool, so the REP it now expects follows right
            // here. The pool and the tokenizer's balance cannot come apart:
            // - only the vault's own transfer runs between the credit and the REP arriving, and it calls no
            //   one, so nothing can act on a pool that is ahead of its balance;
            // - a transfer that failed would revert this whole fork tx, the credit included.
            // On a no nothing was credited, and the excess stays in the pot that is parked below.
            if (queryTokenizer.donateRep(universeId, excess)) {
                donated = excess;
                repToken.safeTransfer(address(queryTokenizer), excess);
            }
        }
        emit Multiverse.TipsCapped(universeId, tips, carried, donated);
    }

    /* ============================================= SPAWN FUNCTIONS ============================================= */
    /**
     * @notice Validates the outcome and spawns the child universe for it.
     * @dev Lazy per-child deployment: only outcomes somebody pays to spawn get a universe, at any time
     *      after the fork — the spawn window never closes. A child spawned after the migration window
     *      closes can no longer receive counted migrations, so it can never be the favorite child or
     *      canonical, but it is a full universe: Zoltar REP wraps into it and it runs queries and forks
     *      of its own. Spawning stays sequential: the parent must itself be a forked Lituus universe, so
     *      a Zoltar lineage with no Lituus record is walked one level at a time (mirror, spawn, mirror, ...).
     *      The outcome must be a valid outcome of the forking query: 1..numberOfOutcomes or INVALID for a
     *      Lituus fork; for a mirrored Zoltar fork any answer Zoltar deems well-formed (categorical
     *      0 = Invalid, 1..n; scalar encodings). The child's fee state is seeded by the Multiverse after
     *      this returns (see Multiverse.spawnChildUniverse).
     * @return childUniverseId The spawned child.
     */
    function spawnChildUniverse(
        mapping(uint248 universeId => Multiverse.Universe) storage universes,
        mapping(uint256 queryId => Multiverse.Query) storage queries,
        mapping(uint248 universeId => mapping(uint256 queryId => Multiverse.QueryResolution)) storage queryResolutions,
        IZoltar zoltar,
        IZoltarQuestionData zoltarQuestionData,
        ITokenDeployer tokenDeployer,
        uint256 reportingPeriod,
        uint248 universeId,
        uint256 outcome
    ) external returns (uint248 childUniverseId) {
        Multiverse.Universe storage universe = universes[universeId];
        // The spawn window never closes: a child can be spawned at any time after the fork.
        if (universe.universeState == Multiverse.UniverseState.NotExisting) revert Multiverse.InvalidUniverse();
        if (universe.universeState == Multiverse.UniverseState.Active) revert Multiverse.InvalidUniverseState();

        uint256 forkQueryId = universe.forkQuery;
        // TODO: map outcomeId to Zoltar outcomes.
        Multiverse.Query storage forkQuery = queries[forkQueryId];
        uint8 numberOfOutcomes = forkQuery.numberOfOutcomes;
        if (numberOfOutcomes != 0) {
            // A Lituus-defined outcome set: 1..numberOfOutcomes or INVALID, keyed into Zoltar as-is.
            // TODO (labels/mapping phase): submit real labels and map INVALID to Zoltar's Invalid (0); then
            // Zoltar's rule below covers this branch too.
            if (
                outcome == MultiverseHelpers.UNRESOLVED
                    || (outcome > numberOfOutcomes && outcome != MultiverseHelpers.INVALID)
            ) {
                revert Multiverse.InvalidOutcome();
            }
        } else if (zoltarQuestionData.isMalformedAnswerOption(forkQuery.zoltarQuestionId, outcome)) {
            // A Zoltar-defined outcome set (mirrored fork): the outcome is a Zoltar answer and Zoltar's own
            // rule decides, categorical or scalar alike. Zoltar's deployChild re-checks it; this is only the
            // clean revert.
            revert Multiverse.InvalidOutcome();
        }

        childUniverseId = _spawnChildUniverse(
            universes,
            queries,
            queryResolutions,
            zoltar,
            tokenDeployer,
            reportingPeriod,
            universeId,
            forkQueryId,
            outcome
        );
    }

    /**
     * @notice Creates one child universe for a forking branch and links it into the fork tree.
     * @dev Deploys the Zoltar-side child if needed, then the child's Lituus REP vault through the vault
     *      deployer at the parent's rate (so accrued appreciation carries over), approves the vault to pull
     *      migrated underlying from this contract, and resolves the forking query to the CHILD'S OWN outcome —
     *      every child answers the forking query its own way. Children spawn Active (fully functional
     *      immediately) and non-canonical.
     * @param universeId The parent universe forking.
     * @param queryId The forking query.
     * @param outcome The Zoltar outcome index the child is keyed by. For a Lituus fork it is also the forking
     * query's Lituus outcome (identity keying until the labels/mapping phase); for a mirrored fork it is a
     * Zoltar answer, recorded as-is except Zoltar's Invalid (0), which is recorded as INVALID for now.
     */
    function _spawnChildUniverse(
        mapping(uint248 universeId => Multiverse.Universe) storage universes,
        mapping(uint256 queryId => Multiverse.Query) storage queries,
        mapping(uint248 universeId => mapping(uint256 queryId => Multiverse.QueryResolution)) storage queryResolutions,
        IZoltar zoltar,
        ITokenDeployer tokenDeployer,
        uint256 reportingPeriod,
        uint248 universeId,
        uint256 queryId,
        uint256 outcome
    ) private returns (uint248 childUniverseId) {
        childUniverseId = zoltar.getChildUniverseId(universeId, outcome);
        if (childUniverseId == 0) revert Multiverse.InvalidUniverse();
        // Never overwrite an existing universe.
        if (universes[childUniverseId].universeState != Multiverse.UniverseState.NotExisting) {
            revert Multiverse.InvalidUniverse();
        }

        Multiverse.Universe storage parentUniverse = universes[universeId];

        // Deploy the Zoltar-side child only if it does not exist yet (a zero rep token means
        // undeployed): Zoltar's deployChild reverts on an already-deployed universe, and anyone may
        // have deployed it directly at the Zoltar level.
        IReputationToken childUniverseZoltarRepToken = zoltar.getRepToken(childUniverseId);
        if (address(childUniverseZoltarRepToken) == address(0)) {
            zoltar.deployChild(universeId, outcome);
            childUniverseZoltarRepToken = zoltar.getRepToken(childUniverseId);
        }
        // An undeployed/broken Zoltar child reads threshold 0.
        if (zoltar.getForkThreshold(childUniverseId) == 0) revert Multiverse.InvalidUniverse();

        // Deploy a Lituus REP token that wraps the child's Zoltar REP token.
        // The child vault starts at the parent's rate, final since the parent forked.
        // The deployer makes its caller the owner: under DELEGATECALL that is the Multiverse.
        uint256 rate = parentUniverse.repToken.rate();
        ILituusRep childUniverseRepToken = tokenDeployer.deployLituusRep(address(childUniverseZoltarRepToken), rate);
        // migrate() and wrap() through Permit2 bring the underlying here first and wrap it from this contract.
        IERC20(address(childUniverseZoltarRepToken)).forceApprove(address(childUniverseRepToken), type(uint256).max);
        // The child vault spawns with unwrap OPEN: unwrapping child wREP harms nothing — fork
        // accounting is counter-based, and only migrate()/migrateStake() write totalMigratedIn. The
        // pause is only ever set on a universe that forks, permanently, in its own fork tx.

        Multiverse.Universe storage childUniverse = universes[childUniverseId];
        childUniverse.repToken = childUniverseRepToken;
        // Children spawn ACTIVE: fully query-functional immediately.
        childUniverse.universeState = Multiverse.UniverseState.Active;
        // forkTime stays 0: the child has not forked (it is set if/when the child's own fork triggers).
        childUniverse.forkTime = 0;
        childUniverse.parent = universeId;

        // Every child resolves the forking query to its own outcome; descendants inherit it via the
        // ancestor walk
        Multiverse.QueryResolution storage resolution = queryResolutions[childUniverseId][queryId];
        resolution.queryCreateTime = uint48(block.timestamp);
        // Only a Zoltar-defined outcome set lets 0 (Zoltar's Invalid) through the spawn validation.
        // TODO: rework in the labels/mapping phase — temporary Zoltar Invalid (0) -> Lituus INVALID translation.
        resolution.outcome = outcome == 0 ? MultiverseHelpers.INVALID : outcome;
        emit Multiverse.QueryResolved(msg.sender, childUniverseId, queryId, resolution.outcome);
        emit Multiverse.ChildUniverseSpawned(universeId, childUniverseId, outcome);

        // The child draws its copies of the parent's fee and tip aggregates and pays the forking query's reporter,
        // in one draw. The stakes are claimed through migrateStake.
        _fundChildAndPayForkReporter(
            universes,
            queries,
            queryResolutions,
            zoltar,
            reportingPeriod,
            universeId,
            childUniverseId,
            childUniverseRepToken,
            queryId,
            outcome,
            rate
        );
    }

    /// @dev Draws `assets` from the parked migration balance of `universeId` into the child for `outcome` and
    ///      wraps them into the child vault. Zoltar lets each child draw up to the whole parked balance, so a
    ///      draw into one child never reduces what another child can draw.
    ///      Reverts when `assets` make no child share (the vault's ZeroShares): a single wei at a rate above 1.
    ///      A stake claim that small only fails for its caller, who keeps the stake. A spawn must never fail
    ///      that way: the amounts it draws are frozen in the forked parent, so the child could never spawn. It
    ///      does not draw through here: _fundChildAndPayForkReporter draws only for whole child shares.
    function _moveParkedToChild(
        IZoltar zoltar,
        uint248 universeId,
        ILituusRep childRepToken,
        uint256 outcome,
        uint256 assets
    ) private returns (uint256 childShares) {
        zoltar.splitMigrationRep(universeId, assets, outcome);
        childShares = childRepToken.wrap(address(this), assets);
    }

    /// @dev Funds a newly spawned child and pays the forking query's reporter there, out of one draw from the
    ///      parked balance. Every child gets a full copy of what the parent's fork froze for it (Zoltar's
    ///      per-child escrow makes the duplication legal), not counted in totalMigratedIn/totalMigratedOut: the
    ///      copies are not single-spend voting capital, only migrate and migrateStake are votes.
    ///      - Fees: the parent's fee aggregate, which backs the resolutions of every query the child inherits.
    ///        The forking query is resolved in the child here, so its fee is consumed here, like any resolution
    ///        consumes a fee: at most what the aggregate holds (see MultiverseHelpers._consumeQueryFee). The rest
    ///        is the child's totalQueryFees.
    ///      - Tips: the parent's carriedTips. The forking query's are paid here, out of that amount, the way any
    ///        resolution pays tips out of totalTips, cut by the fork's ratio like every other query's (see
    ///        MultiverseHelpers._cutTips). The rest is the child's totalTips.
    ///      - Reporter: the parent's first reporter of `outcome` gets the forking query's tips and its fee ramp,
    ///        measured on the fee consumed. The unpaid part of the fee is never drawn: it stays parked. If nobody
    ///        staked on `outcome`, nothing is owed: the forking query's tips and fee stay parked.
    ///      A mirrored fork has no forking query with stakes: its child keeps the whole fee aggregate and all the
    ///      carried tips, and pays nobody.
    /// @param rate The parent's rate, final since its fork: the child's vault opens at it.
    function _fundChildAndPayForkReporter(
        mapping(uint248 universeId => Multiverse.Universe) storage universes,
        mapping(uint256 queryId => Multiverse.Query) storage queries,
        mapping(uint248 universeId => mapping(uint256 queryId => Multiverse.QueryResolution)) storage queryResolutions,
        IZoltar zoltar,
        uint256 reportingPeriod,
        uint248 universeId,
        uint248 childUniverseId,
        ILituusRep childRepToken,
        uint256 queryId,
        uint256 outcome,
        uint256 rate
    ) private {
        Multiverse.Universe storage parentUniverse = universes[universeId];

        // 1. Split what the parent froze, in its shares: the forking query's fee and tips come off the copies.
        //    carried = forkQueryTips (the forking query's, cut like every other query's) + childTips (the rest).
        uint256 fees = parentUniverse.totalQueryFees;
        uint256 carried = parentUniverse.carriedTips;
        uint256 forkQueryTips;
        address reporter;
        uint256 feeShare;
        if (parentUniverse.isLituusFork) {
            uint256 forkQueryFee = queries[queryId].fee;
            if (forkQueryFee > fees) forkQueryFee = fees;
            fees -= forkQueryFee;
            Multiverse.QueryResolution storage resolution = queryResolutions[universeId][queryId];
            Multiverse.OutcomeStakes storage winnerStakes = resolution.outcomes[outcome];
            // Nothing carried: nothing to split, and the record's tips are not read.
            if (carried != 0) {
                forkQueryTips = MultiverseHelpers._cutTips(resolution.tips, carried, parentUniverse.totalTips);
            }
            reporter = winnerStakes.firstReporter;
            if (reporter != address(0)) {
                // Ramps to the full fee over the reporting window, like the non-fork resolution.
                feeShare = MultiverseHelpers._timeBasedFeeShare(
                    forkQueryFee, winnerStakes.firstReportTime - resolution.queryCreateTime, reportingPeriod
                );
            }
        }
        // The record's tips are part of the parent's totalTips, so their cut is at most `carried`.
        uint256 childTips = carried - forkQueryTips;
        // The forking query's tips are owed to the first reporter of this child's outcome. If nobody staked on
        // it, they are not drawn and stay parked.
        uint256 reporterTips = reporter == address(0) ? 0 : forkQueryTips;

        // 2. What each part makes in the child. The tips are whole child shares already: the fork tx rounded
        //    carriedTips (see _capCarriedTips). The fee aggregate and the fee share go through the rate rounded
        //    down, as a draw of their own would: the child's aggregate can come out a wei short, and an amount
        //    that makes no child share stays parked.
        uint256 childFees = _asChildShares(fees, rate);
        uint256 reporterShares = reporterTips + _asChildShares(feeShare, rate);
        uint256 shares = childFees + childTips + reporterShares;
        if (shares == 0) return;

        // 3. One draw: the REP those shares cost, rounded up. Each part's shares are at most its REP at the rate,
        //    so this is never more than drawing each part on its own would take: it stays within what the pot
        //    holds for them. The child's vault mints exactly `shares` for it, at any rate: wrapShares pulls the
        //    shares' cost rounded up at the vault's rate, which is `rate`, so the same REP the split drew.
        zoltar.splitMigrationRep(universeId, LituusRepMath.toAssetsUp(shares, rate), outcome);
        childRepToken.wrapShares(address(this), shares);

        // 4. The child keeps its parts, and the reporter gets the rest.
        Multiverse.Universe storage childUniverse = universes[childUniverseId];
        // Share amounts are REP amounts within uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (childFees != 0) childUniverse.totalQueryFees = uint128(childFees);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (childTips != 0) childUniverse.totalTips = uint128(childTips);
        // Nothing owed: nobody staked on this outcome, or no tips and a fee share that makes no child share.
        if (reporterShares == 0) return;
        childRepToken.safeTransfer(reporter, reporterShares);
        emit Multiverse.ReporterRewardPaid(
            reporter, childUniverseId, queryId, reporterShares - reporterTips, reporterTips
        );
    }

    /// @dev What `shares` of a forked universe make in a child's vault, which opens at the forked universe's
    ///      `rate`: shares to REP and back, both rounded down, as a draw of them would mint.
    function _asChildShares(uint256 shares, uint256 rate) private pure returns (uint256) {
        return LituusRepMath.toShares(LituusRepMath.toAssets(shares, rate), rate);
    }

    /* =========================================== MIGRATION FUNCTIONS =========================================== */
    /**
     * @dev Only during the 30-day window, self-enforced by clock. The target child must already be
     *      spawned (spawnChildUniverse is permissionless). The caller's parent wREP is burned via the
     *      migrateOut lane; the underlying routes through Zoltar migration into the
     *      child's REP, is wrapped into the child vault, and the child wREP is credited to the
     *      caller. Migration is burn-based and irreversible.
     */
    function migrate(
        mapping(uint248 universeId => Multiverse.Universe) storage universes,
        IZoltar zoltar,
        uint248 genesisUniverseId,
        uint256 migrationDuration,
        uint248 universeId,
        uint256 outcome,
        uint256 shares
    ) external returns (uint248 childUniverseId, uint256 childShares) {
        Multiverse.Universe storage universe;
        Multiverse.Universe storage childUniverse;
        (universe, childUniverse, childUniverseId) =
            _migrationTarget(universes, zoltar, genesisUniverseId, migrationDuration, universeId, outcome);

        // Burn the caller's parent wREP and take the underlying (pause-exempt, rate-preserving
        // owner lane — the forked vault is permanently unwrap-paused).
        uint256 assets = universe.repToken.migrateOut(msg.sender, shares);
        // Route the underlying through Zoltar migration into the child's REP
        zoltar.addRepToMigrationBalance(universeId, assets);
        zoltar.splitMigrationRep(universeId, assets, outcome);
        // Wrap it into the child vault (pulls via the spawn-time approval) and credit the caller.
        childShares = childUniverse.repToken.wrap(address(this), assets);
        childUniverse.repToken.safeTransfer(msg.sender, childShares);

        // Count the vote in underlying assets (what actually flowed through Lituus).
        _countMigration(universe, childUniverse, childUniverseId, assets);

        emit Multiverse.Migrated(msg.sender, universeId, childUniverseId, assets);
    }

    /**
     * @dev The stake record stays in the parent; the payout is drawn from the parked migration balance, which
     *      Zoltar tracks per child. Zeroing the stake before any transfer makes it claimable once. What leaves
     *      the parked supply counts as a migration vote for the child: the whole payout for a resolved query's
     *      winner and for a refund, since each moves once, into one child; only the principal for the forking
     *      query, whose winnings are paid in every child. Open for as long as migrate() is: the vote is
     *      counted, so it cannot land after the fork is resolved.
     */
    function migrateStake(
        mapping(uint248 universeId => Multiverse.Universe) storage universes,
        mapping(
            uint248 universeId
                => mapping(
                uint256 queryId => Multiverse.QueryResolution
            )
        ) storage queryResolutions,
        IZoltar zoltar,
        uint248 genesisUniverseId,
        uint256 migrationDuration,
        uint248 universeId,
        uint256 queryId,
        uint256 outcome,
        uint256 childOutcome
    ) external {
        (Multiverse.Universe storage universe, Multiverse.Universe storage childUniverse, uint248 childUniverseId) =
            _migrationTarget(universes, zoltar, genesisUniverseId, migrationDuration, universeId, childOutcome);

        (uint256 assets, uint256 vote) =
            _settleStakeForMigration(queryResolutions, universeId, universe, queryId, outcome, childOutcome);

        ILituusRep childRepToken = childUniverse.repToken;
        uint256 childShares = _moveParkedToChild(zoltar, universeId, childRepToken, childOutcome, assets);
        childRepToken.safeTransfer(msg.sender, childShares);

        _countStakeMigration(universe, childUniverse, childUniverseId, vote);

        emit Multiverse.StakeMigrated(msg.sender, universeId, childUniverseId, queryId, assets);
    }

    /**
     * @dev A repeated (query, outcome) pair reverts on its second occurrence (the stake is already zeroed),
     *      failing the whole batch. The forking query can be part of the batch only when `childOutcome` is
     *      the outcome staked on.
     */
    function migrateStakes(
        mapping(uint248 universeId => Multiverse.Universe) storage universes,
        mapping(
            uint248 universeId
                => mapping(
                uint256 queryId => Multiverse.QueryResolution
            )
        ) storage queryResolutions,
        IZoltar zoltar,
        uint248 genesisUniverseId,
        uint256 migrationDuration,
        uint248 universeId,
        uint256[] calldata queryIds,
        uint256[] calldata outcomes,
        uint256 childOutcome
    ) external {
        uint256 length = queryIds.length;
        if (length == 0 || length != outcomes.length) revert Multiverse.InvalidClaimBatch();

        (Multiverse.Universe storage universe, Multiverse.Universe storage childUniverse, uint248 childUniverseId) =
            _migrationTarget(universes, zoltar, genesisUniverseId, migrationDuration, universeId, childOutcome);

        uint256 totalAssets;
        uint256 totalVote;
        for (uint256 i = 0; i < length;) {
            (uint256 assets, uint256 vote) =
                _settleStakeForMigration(queryResolutions, universeId, universe, queryIds[i], outcomes[i], childOutcome);
            totalAssets += assets;
            totalVote += vote;

            emit Multiverse.StakeMigrated(msg.sender, universeId, childUniverseId, queryIds[i], assets);

            unchecked {
                i += 1;
            }
        }

        ILituusRep childRepToken = childUniverse.repToken;
        uint256 childShares = _moveParkedToChild(zoltar, universeId, childRepToken, childOutcome, totalAssets);
        childRepToken.safeTransfer(msg.sender, childShares);

        _countStakeMigration(universe, childUniverse, childUniverseId, totalVote);
    }

    /// @dev The gate every migration lane out of `universeId` into the child of `childOutcome` passes: the
    ///      universe is migrating, its window is open and the child is spawned.
    function _migrationTarget(
        mapping(uint248 universeId => Multiverse.Universe) storage universes,
        IZoltar zoltar,
        uint248 genesisUniverseId,
        uint256 migrationDuration,
        uint248 universeId,
        uint256 childOutcome
    )
        private
        view
        returns (
            Multiverse.Universe storage universe,
            Multiverse.Universe storage childUniverse,
            uint248 childUniverseId
        )
    {
        universe = universes[universeId];
        if (universe.universeState != Multiverse.UniverseState.Migration) revert Multiverse.InvalidUniverseState();
        if (!_isMigrationWindowOpen(universes, genesisUniverseId, migrationDuration, universeId, universe)) {
            revert Multiverse.MigrationWindowClosed();
        }

        // The child is keyed by the outcome exactly as spawnChildUniverse keyed it, and it must exist: spawn
        // it first (permissionless) if this outcome has none yet.
        childUniverseId = zoltar.getChildUniverseId(universeId, childOutcome);
        childUniverse = universes[childUniverseId];
        if (childUniverse.universeState == Multiverse.UniverseState.NotExisting) revert Multiverse.InvalidUniverse();
    }

    /// @dev Whether a forking universe still takes migrations into its children. The window closes in
    ///      MIGRATION_DURATION after the fork, but not before the parent's own fork is resolved: a nested
    ///      fork cannot finish migrating while the parent is still migrating.
    function _isMigrationWindowOpen(
        mapping(uint248 universeId => Multiverse.Universe) storage universes,
        uint248 genesisUniverseId,
        uint256 migrationDuration,
        uint248 universeId,
        Multiverse.Universe storage universe
    ) private view returns (bool) {
        bool isParentForkResolved = universeId == genesisUniverseId
            || universes[universe.parent].universeState == Multiverse.UniverseState.PostFork;
        return block.timestamp < uint256(universe.forkTime) + migrationDuration || !isParentForkResolved;
    }

    /// @dev Settles the caller's stake on `queryId` for migration into the child of `childOutcome`: zeroes it
    ///      and returns what the child pays out and how much of that votes, both in underlying assets at the
    ///      parent's rate, frozen since the fork. The three cases are those of migrateStake.
    function _settleStakeForMigration(
        mapping(uint248 universeId => mapping(uint256 queryId => Multiverse.QueryResolution)) storage queryResolutions,
        uint248 universeId,
        Multiverse.Universe storage universe,
        uint256 queryId,
        uint256 outcome,
        uint256 childOutcome
    ) private returns (uint256 assets, uint256 vote) {
        Multiverse.QueryResolution storage resolution = queryResolutions[universeId][queryId];
        uint256 amount = resolution.userStakes[msg.sender][outcome];
        if (amount == 0) revert Multiverse.NothingToClaim();

        ILituusRep repToken = universe.repToken;
        if (queryId == universe.forkQuery) {
            // The child resolves the forking query to its own outcome, so only that outcome wins there.
            if (outcome != childOutcome) revert Multiverse.NotAWinningOutcome();
            assets = repToken.convertToAssets(_forkPayout(resolution, amount));
            // Only the principal votes: the winnings on top of it are paid in every child.
            vote = repToken.convertToAssets(amount);
        } else if (resolution.outcome != MultiverseHelpers.UNRESOLVED) {
            // Resolved before the fork: the burn on the losing side was taken at resolution, so the winner's
            // payout is exactly what the pot still holds for it.
            if (outcome != resolution.outcome) revert Multiverse.NotAWinningOutcome();
            assets = repToken.convertToAssets(MultiverseHelpers._winningPayout(resolution, outcome, amount));
            vote = assets;
        } else {
            // Unresolved at the fork: the game restarts in the children, the stake comes back as it was.
            assets = repToken.convertToAssets(amount);
            vote = assets;
        }

        // Zeroed is the settled flag, set before any transfer happens in the callers.
        resolution.userStakes[msg.sender][outcome] = 0;
    }

    /// @dev A forking query stake's payout in the child of its outcome. Nothing is burned at the Lituus level in
    ///      a fork: what Zoltar kept of the fork bond is the burn, and it comes off the losing side. Every child
    ///      pays the same return, the one the outcomes at the cap get, which is the lowest of all. The outcomes
    ///      at the cap hold exactly `cap` each and nothing holds more, so their losing side is
    ///      `totalStaked - cap`. A smaller outcome gets the same multiplier instead of the whole of the other
    ///      outcomes, and the rest of its losing side is never drawn from the parked balance. The burn is at
    ///      most a fifth of the bond, which is two caps, so it never exceeds the losing side.
    function _forkPayout(Multiverse.QueryResolution storage resolution, uint256 amount) private view returns (uint256) {
        uint256 cap = resolution.cap;
        uint256 totalDistributable = resolution.totalStaked - cap - resolution.forkBurn;
        return amount + amount * totalDistributable / cap;
    }

    /// @dev Records `assets` of REP moving out of a forking universe into one of its children through a counted
    ///      lane: the parent's outflow (the electorate at the end of migration), the child's inflow, and the
    ///      running max that designates the fork's leader.
    function _countMigration(
        Multiverse.Universe storage universe,
        Multiverse.Universe storage childUniverse,
        uint248 childUniverseId,
        uint256 assets
    ) private {
        // Asset amounts are REP amounts within uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.totalMigratedOut += uint128(assets);
        // forge-lint: disable-next-line(unsafe-typecast)
        childUniverse.totalMigratedIn += uint128(assets);
        if (childUniverse.totalMigratedIn > universe.maxMigratedOut) {
            universe.maxMigratedOut = childUniverse.totalMigratedIn;
            universe.favoriteChild = childUniverseId;
        }
    }

    /// @dev Books a stake migration: the vote leaves the parked supply and counts for the child.
    function _countStakeMigration(
        Multiverse.Universe storage universe,
        Multiverse.Universe storage childUniverse,
        uint248 childUniverseId,
        uint256 vote
    ) private {
        // Asset amounts are REP amounts within uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        universe.unmigratedSupply -= uint128(vote);
        _countMigration(universe, childUniverse, childUniverseId, vote);
    }

    /* ========================================== FORK RESOLUTION ============================================== */
    /**
     * @dev For now it always resolves the fork: designates the winner and moves the universe to
     *      PostFork. Later it will check the max amount migrated (2/3 of totalMigratedOut, both
     *      read live here at the end of migration) and either resolve the fork or start the supply
     *      restoration and the auction.
     *      Root-first ordering: a nested fork cannot resolve before its parent's fork has resolved.
     * @return newCanonicalHeir The winner if this resolution moves the canonical timeline, 0 otherwise.
     */
    function advanceForkState(
        mapping(uint248 universeId => Multiverse.Universe) storage universes,
        uint248 genesisUniverseId,
        uint256 migrationDuration,
        uint248 universeId
    ) external returns (uint248 newCanonicalHeir) {
        Multiverse.Universe storage universe = universes[universeId];
        if (universe.universeState != Multiverse.UniverseState.Migration) revert Multiverse.InvalidUniverseState();
        // Root-first: the parent's fork must be resolved before this universe's fork can advance
        // (the genesis, having no parent, is exempt).
        bool isParentForkResolved = universeId == genesisUniverseId
            || universes[universe.parent].universeState == Multiverse.UniverseState.PostFork;
        if (!isParentForkResolved) revert Multiverse.ParentForkNotResolved();

        if (block.timestamp < uint256(universe.forkTime) + migrationDuration) {
            revert Multiverse.MigrationWindowNotClosed();
        }

        // The winner is the running max, already in favoriteChild. Only a canonical universe's
        // resolution moves the canonical timeline.
        uint248 winner = universe.favoriteChild;
        if (winner != 0 && universe.isCanonical) {
            universes[winner].isCanonical = true;
            newCanonicalHeir = winner;
        }

        universe.universeState = Multiverse.UniverseState.PostFork;
        // The vault stays paused forever: unmigrated wREP's recourse is the Lituus claim/migration
        // lanes, not a Zoltar-level exit.
    }
}
