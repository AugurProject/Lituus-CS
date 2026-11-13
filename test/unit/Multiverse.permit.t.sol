// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import { Multiverse } from "src/Multiverse.sol";
import { LituusRep } from "src/LituusRep.sol";
import { PermitSupport } from "src/PermitSupport.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { IPermit2 } from "src/interfaces/IPermit2.sol";
import { MultiverseFixtures } from "./Multiverse.fixtures.sol";
import { PermitSigning } from "../utils/PermitSigning.sol";

/// @notice Paying the Multiverse in the same transaction that approves it: an ERC-2612 permit on wREP relayed
///         through permitRep, or a Permit2 allowance relayed through permit2, each followed by the action in one
///         multicall. The plain approve-then-call path is untouched and still comes first.
contract MultiversePermitTest is MultiverseFixtures, PermitSigning {
    uint256 internal constant SIGNER_REP = 100 ether;
    uint256 internal constant SIGNER_UNDERLYING = 50 ether;
    uint256 internal constant TIP = 5 ether;

    address internal signer;
    uint256 internal signerKey;
    address internal stranger;
    uint256 internal strangerKey;

    function setUp() public override {
        super.setUp();
        (signer, signerKey) = makeAddrAndKey("signer");
        (stranger, strangerKey) = makeAddrAndKey("stranger");
        _fundWithRep(signer, SIGNER_REP);
        // The funding helper approves the Multiverse on wREP and the vault on the underlying; these tests start
        // from no allowance of any kind.
        vm.startPrank(signer);
        genesisRep.approve(address(multiverse), 0);
        underlying.approve(address(genesisRep), 0);
        vm.stopPrank();
        underlying.transfer(signer, SIGNER_UNDERLYING);
    }

    /* ============================================== HELPERS =============================================== */

    /// @dev The fee the next createQuery charges, read off the production preview.
    function _nextFee() internal view returns (uint256) {
        return _previewUncappedFee();
    }

    function _createQueryCall() internal pure returns (bytes memory) {
        return abi.encodeCall(Multiverse.createQuery, (GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES));
    }

    function _permitRepCall(uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(Multiverse.permitRep, (GENESIS_UID, value, deadline, v, r, s));
    }

    function _permit2Call(IPermit2.PermitSingle memory permitSingle, bytes memory signature)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(PermitSupport.permit2, (permitSingle, signature));
    }

    function _tipCall(uint256 queryId, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(Multiverse.tip, (GENESIS_UID, queryId, amount));
    }

    function _multicall(address caller, bytes memory first, bytes memory second) internal {
        bytes[] memory calls = new bytes[](2);
        calls[0] = first;
        calls[1] = second;
        vm.prank(caller);
        multiverse.multicall(calls);
    }

    /// @dev The signer's permit for the Multiverse on genesis wREP, at the current nonce.
    function _signerPermit(uint256 value, uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        return _signPermit(genesisRep, signerKey, address(multiverse), value, deadline);
    }

    /// @dev The signer's Permit2 grant to the Multiverse on `token`, signed, after the one-time approval of
    ///      Permit2 on that token.
    function _signerPermit2(address token, uint160 amount)
        internal
        returns (IPermit2.PermitSingle memory permitSingle, bytes memory signature)
    {
        vm.prank(signer);
        LituusRep(token).approve(address(permit2), type(uint256).max);
        permitSingle = _permitSingle(permit2, signer, token, amount, address(multiverse));
        signature = _signPermit2(permit2, signerKey, permitSingle);
    }

    function _permit2Allowance(address token) internal view returns (uint160 amount) {
        (amount,,) = permit2.allowance(signer, token, address(multiverse));
    }

    /* ======================================== ERC-2612 ON THE VAULT ======================================== */

    function test_LituusRep_PermitSetsAllowanceAndSpendsTheNonce() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signerPermit(3 ether, deadline);
        assertEq(genesisRep.nonces(signer), 0);

        // Anyone can submit a permit; the allowance lands on the signer.
        vm.prank(stranger);
        genesisRep.permit(signer, address(multiverse), 3 ether, deadline, v, r, s);

        assertEq(genesisRep.allowance(signer, address(multiverse)), 3 ether);
        assertEq(genesisRep.nonces(signer), 1);
        // The same signature cannot be replayed.
        vm.expectRevert();
        genesisRep.permit(signer, address(multiverse), 3 ether, deadline, v, r, s);
    }

    /* =========================================== PERMIT + ACTION =========================================== */

    function test_PermitRep_ThenCreateQueryInOneTransaction() public {
        uint256 fee = _nextFee();
        (uint8 v, bytes32 r, bytes32 s) = _signerPermit(fee, vm.getBlockTimestamp() + 1 hours);
        uint256 queryId = multiverse.queryCount();

        _multicall(signer, _permitRepCall(fee, vm.getBlockTimestamp() + 1 hours, v, r, s), _createQueryCall());

        assertEq(multiverse.queryCount(), queryId + 1);
        (,, uint256 recordedFee,,) = multiverse.queries(queryId);
        assertEq(recordedFee, fee);
        assertEq(genesisRep.balanceOf(signer), SIGNER_REP - fee);
        // The permit granted exactly the fee, and the fee spent it.
        assertEq(genesisRep.allowance(signer, address(multiverse)), 0);
        assertEq(genesisRep.nonces(signer), 1);
    }

    function test_PermitRep_ThenReportInOneTransaction() public {
        uint256 queryId = _createDefaultQuery();
        uint256 stake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_A);
        (uint8 v, bytes32 r, bytes32 s) = _signerPermit(stake, vm.getBlockTimestamp() + 1 hours);

        _multicall(
            signer,
            _permitRepCall(stake, vm.getBlockTimestamp() + 1 hours, v, r, s),
            abi.encodeCall(Multiverse.report, (GENESIS_UID, queryId, OUTCOME_A))
        );

        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, signer, OUTCOME_A), stake);
        assertEq(genesisRep.balanceOf(signer), SIGNER_REP - stake);
        assertEq(genesisRep.allowance(signer, address(multiverse)), 0);
    }

    function test_PermitRep_GoesThroughWhenSomeoneSubmittedThePermitFirst() public {
        uint256 fee = _nextFee();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signerPermit(fee, deadline);

        // The signature is public the moment the transaction is in the mempool; a stranger submits it to the
        // vault first. The permit inside the multicall then fails on the spent nonce, but the allowance it set
        // is in place, so the signer's transaction still goes through.
        vm.prank(stranger);
        genesisRep.permit(signer, address(multiverse), fee, deadline, v, r, s);
        uint256 queryId = multiverse.queryCount();

        _multicall(signer, _permitRepCall(fee, deadline, v, r, s), _createQueryCall());

        assertEq(multiverse.queryCount(), queryId + 1);
        assertEq(genesisRep.balanceOf(signer), SIGNER_REP - fee);
    }

    function test_PermitRep_AnExistingAllowanceCoversAnInvalidPermit() public {
        // What has to hold is the allowance, not the permit: a stale signature on top of a standing approval
        // changes nothing and blocks nothing.
        vm.prank(signer);
        genesisRep.approve(address(multiverse), 10 ether);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(genesisRep, strangerKey, address(multiverse), 1, 0);

        vm.prank(signer);
        multiverse.permitRep(GENESIS_UID, 5 ether, 0, v, r, s);

        assertEq(genesisRep.allowance(signer, address(multiverse)), 10 ether);
        assertEq(genesisRep.nonces(signer), 0);
    }

    function test_RevertWhen_PermitRep_Expired() public {
        uint256 fee = _nextFee();
        uint256 deadline = vm.getBlockTimestamp() - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signerPermit(fee, deadline);

        vm.expectRevert(PermitSupport.PermitNotEffective.selector);
        _multicall(signer, _permitRepCall(fee, deadline, v, r, s), _createQueryCall());
    }

    function test_RevertWhen_PermitRep_SignedByAnotherKey() public {
        uint256 fee = _nextFee();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(genesisRep, strangerKey, address(multiverse), fee, deadline);

        vm.prank(signer);
        vm.expectRevert(PermitSupport.PermitNotEffective.selector);
        multiverse.permitRep(GENESIS_UID, fee, deadline, v, r, s);
    }

    function test_RevertWhen_PermitRep_ShortOfTheValueAsked() public {
        // The signature grants less than the call claims: the allowance is set, and still short.
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signerPermit(1 ether, deadline);

        vm.prank(signer);
        vm.expectRevert(PermitSupport.PermitNotEffective.selector);
        multiverse.permitRep(GENESIS_UID, 2 ether, deadline, v, r, s);
    }

    function test_RevertWhen_PermitRep_UniverseNotExisting() public {
        vm.prank(signer);
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        multiverse.permitRep(GENESIS_UID + 1, 1 ether, vm.getBlockTimestamp() + 1 hours, 27, bytes32(0), bytes32(0));
    }

    /* ============================================ PERMIT2 + ACTION ========================================== */

    function test_Permit2_ThenCreateQueryInOneTransaction() public {
        uint256 fee = _nextFee();
        (IPermit2.PermitSingle memory permitSingle, bytes memory signature) =
            _signerPermit2(address(genesisRep), uint160(fee));
        uint256 queryId = multiverse.queryCount();

        _multicall(signer, _permit2Call(permitSingle, signature), _createQueryCall());

        assertEq(multiverse.queryCount(), queryId + 1);
        assertEq(genesisRep.balanceOf(signer), SIGNER_REP - fee);
        // No plain allowance was ever involved; the Permit2 allowance was spent down.
        assertEq(genesisRep.allowance(signer, address(multiverse)), 0);
        assertEq(_permit2Allowance(address(genesisRep)), 0);
    }

    function test_Permit2_ThenReportInOneTransaction() public {
        uint256 queryId = _createDefaultQuery();
        uint256 stake = multiverse.getNextRequiredStake(GENESIS_UID, queryId, OUTCOME_A);
        (IPermit2.PermitSingle memory permitSingle, bytes memory signature) =
            _signerPermit2(address(genesisRep), uint160(stake));

        _multicall(
            signer,
            _permit2Call(permitSingle, signature),
            abi.encodeCall(Multiverse.report, (GENESIS_UID, queryId, OUTCOME_A))
        );

        assertEq(multiverse.getUserStake(GENESIS_UID, queryId, signer, OUTCOME_A), stake);
        assertEq(genesisRep.balanceOf(signer), SIGNER_REP - stake);
    }

    function test_Permit2_OneAllowanceCoversSeveralActions() public {
        // A Permit2 allowance is a budget with an expiry, not a one-shot: two queries draw on the same grant.
        (IPermit2.PermitSingle memory permitSingle, bytes memory signature) =
            _signerPermit2(address(genesisRep), uint160(10 ether));
        vm.prank(signer);
        multiverse.permit2(permitSingle, signature);

        uint256 firstFee = _nextFee();
        vm.prank(signer);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
        uint256 secondFee = _nextFee();
        vm.prank(signer);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        assertEq(genesisRep.balanceOf(signer), SIGNER_REP - firstFee - secondFee);
        assertEq(_permit2Allowance(address(genesisRep)), 10 ether - firstFee - secondFee);
    }

    function test_Permit2_GoesThroughWhenSomeoneSubmittedThePermitFirst() public {
        uint256 fee = _nextFee();
        (IPermit2.PermitSingle memory permitSingle, bytes memory signature) =
            _signerPermit2(address(genesisRep), uint160(fee));

        // Same race as with the vault permit: a stranger relays the signature straight to Permit2 first.
        vm.prank(stranger);
        permit2.permit(signer, permitSingle, signature);
        uint256 queryId = multiverse.queryCount();

        _multicall(signer, _permit2Call(permitSingle, signature), _createQueryCall());

        assertEq(multiverse.queryCount(), queryId + 1);
        assertEq(genesisRep.balanceOf(signer), SIGNER_REP - fee);
    }

    function test_RevertWhen_Permit2_SpenderIsNotTheMultiverse() public {
        vm.prank(signer);
        genesisRep.approve(address(permit2), type(uint256).max);
        IPermit2.PermitSingle memory permitSingle =
            _permitSingle(permit2, signer, address(genesisRep), 1 ether, stranger);
        bytes memory signature = _signPermit2(permit2, signerKey, permitSingle);

        // The permit itself is valid and lands, for the stranger; the relay only cares about its own allowance.
        vm.prank(signer);
        vm.expectRevert(PermitSupport.PermitNotEffective.selector);
        multiverse.permit2(permitSingle, signature);
    }

    function test_RevertWhen_Permit2_SignatureExpired() public {
        vm.prank(signer);
        genesisRep.approve(address(permit2), type(uint256).max);
        IPermit2.PermitSingle memory permitSingle =
            _permitSingle(permit2, signer, address(genesisRep), 1 ether, address(multiverse));
        permitSingle.sigDeadline = vm.getBlockTimestamp() - 1;
        bytes memory signature = _signPermit2(permit2, signerKey, permitSingle);

        vm.prank(signer);
        vm.expectRevert(PermitSupport.PermitNotEffective.selector);
        multiverse.permit2(permitSingle, signature);
    }

    function test_RevertWhen_Permit2_SignedByAnotherKey() public {
        vm.prank(signer);
        genesisRep.approve(address(permit2), type(uint256).max);
        IPermit2.PermitSingle memory permitSingle =
            _permitSingle(permit2, signer, address(genesisRep), 1 ether, address(multiverse));
        bytes memory signature = _signPermit2(permit2, strangerKey, permitSingle);

        vm.prank(signer);
        vm.expectRevert(PermitSupport.PermitNotEffective.selector);
        multiverse.permit2(permitSingle, signature);
    }

    /* ============================================== THE PULL =============================================== */

    function test_Pull_TakesThePlainAllowanceFirst() public {
        // With both in place the plain allowance pays and the Permit2 budget is left alone.
        uint256 fee = _nextFee();
        vm.prank(signer);
        genesisRep.approve(address(multiverse), fee);
        (IPermit2.PermitSingle memory permitSingle, bytes memory signature) =
            _signerPermit2(address(genesisRep), uint160(10 ether));
        vm.prank(signer);
        multiverse.permit2(permitSingle, signature);

        vm.prank(signer);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        assertEq(genesisRep.allowance(signer, address(multiverse)), 0);
        assertEq(_permit2Allowance(address(genesisRep)), 10 ether);
    }

    function test_Pull_FallsBackToPermit2WhenThePlainAllowanceIsShort() public {
        uint256 fee = _nextFee();
        vm.prank(signer);
        genesisRep.approve(address(multiverse), fee - 1);
        (IPermit2.PermitSingle memory permitSingle, bytes memory signature) =
            _signerPermit2(address(genesisRep), uint160(fee));
        vm.prank(signer);
        multiverse.permit2(permitSingle, signature);

        vm.prank(signer);
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);

        // The short plain allowance is untouched; Permit2 paid the whole fee.
        assertEq(genesisRep.allowance(signer, address(multiverse)), fee - 1);
        assertEq(_permit2Allowance(address(genesisRep)), 0);
    }

    function test_RevertWhen_Pull_NoAllowanceAnywhere() public {
        // Permit2 is the last resort, so its error is what a caller with no allowance at all sees.
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(AllowanceExpired.selector, 0));
        multiverse.createQuery(GENESIS_UID, DEFAULT_QUESTION, DEFAULT_NUMBER_OF_OUTCOMES);
    }

    function test_Multicall_AFailedStepRevertsTheWhole() public {
        uint256 fee = _nextFee();
        uint256 deadline = vm.getBlockTimestamp() - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signerPermit(fee, deadline);
        uint256 queryCount = multiverse.queryCount();

        vm.expectRevert(PermitSupport.PermitNotEffective.selector);
        _multicall(signer, _permitRepCall(fee, deadline, v, r, s), _createQueryCall());

        assertEq(multiverse.queryCount(), queryCount);
        assertEq(genesisRep.balanceOf(signer), SIGNER_REP);
    }

    /* ================================================ TIP ================================================== */

    function test_PermitRep_ThenTipInOneTransaction() public {
        uint256 queryId = _createDefaultQuery();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signerPermit(TIP, deadline);
        uint256 multiverseBefore = genesisRep.balanceOf(address(multiverse));

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryTipped(signer, GENESIS_UID, queryId, TIP);
        _multicall(signer, _permitRepCall(TIP, deadline, v, r, s), _tipCall(queryId, TIP));

        assertEq(multiverse.getTips(GENESIS_UID, queryId), TIP);
        assertEq(genesisRep.balanceOf(signer), SIGNER_REP - TIP);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBefore + TIP);
        // The permit granted exactly the tip, and the tip spent it.
        assertEq(genesisRep.allowance(signer, address(multiverse)), 0);
        assertEq(genesisRep.nonces(signer), 1);
    }

    function test_Permit2_ThenTipInOneTransaction() public {
        uint256 queryId = _createDefaultQuery();
        (IPermit2.PermitSingle memory permitSingle, bytes memory signature) =
            _signerPermit2(address(genesisRep), uint160(TIP));
        uint256 multiverseBefore = genesisRep.balanceOf(address(multiverse));

        vm.expectEmit(true, true, true, true, address(multiverse));
        emit Multiverse.QueryTipped(signer, GENESIS_UID, queryId, TIP);
        _multicall(signer, _permit2Call(permitSingle, signature), _tipCall(queryId, TIP));

        assertEq(multiverse.getTips(GENESIS_UID, queryId), TIP);
        assertEq(genesisRep.balanceOf(signer), SIGNER_REP - TIP);
        assertEq(genesisRep.balanceOf(address(multiverse)), multiverseBefore + TIP);
        // No plain allowance was ever involved; the Permit2 allowance was spent down.
        assertEq(genesisRep.allowance(signer, address(multiverse)), 0);
        assertEq(_permit2Allowance(address(genesisRep)), 0);
    }

    function test_Permit2_CreateQueryAndTipItInOneTransaction() public {
        // A creator who wants the query picked up fast tips it in the same transaction: one Permit2 grant covers
        // both the fee and the tip.
        uint256 fee = _nextFee();
        (IPermit2.PermitSingle memory permitSingle, bytes memory signature) =
            _signerPermit2(address(genesisRep), uint160(fee + TIP));
        uint256 queryId = multiverse.queryCount();

        bytes[] memory calls = new bytes[](3);
        calls[0] = _permit2Call(permitSingle, signature);
        calls[1] = _createQueryCall();
        calls[2] = _tipCall(queryId, TIP);
        vm.prank(signer);
        multiverse.multicall(calls);

        assertEq(multiverse.queryCount(), queryId + 1);
        assertEq(multiverse.getTips(GENESIS_UID, queryId), TIP);
        assertEq(genesisRep.balanceOf(signer), SIGNER_REP - fee - TIP);
        assertEq(_permit2Allowance(address(genesisRep)), 0);
    }

    function test_RevertWhen_Tip_NoAllowanceAnywhere() public {
        uint256 queryId = _createDefaultQuery();

        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(AllowanceExpired.selector, 0));
        multiverse.tip(GENESIS_UID, queryId, TIP);
    }

    function test_Multicall_ATipBeatenByAReportRevertsThePermitToo() public {
        // The tipper signs, but a report lands first and closes tipping. The whole multicall reverts, so the
        // permit is never used: no allowance is left behind and the nonce stays unspent.
        uint256 queryId = _createDefaultQuery();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signerPermit(TIP, deadline);
        _report(user, queryId, OUTCOME_A);

        vm.expectRevert(Multiverse.QueryAlreadyReported.selector);
        _multicall(signer, _permitRepCall(TIP, deadline, v, r, s), _tipCall(queryId, TIP));

        assertEq(genesisRep.balanceOf(signer), SIGNER_REP);
        assertEq(genesisRep.allowance(signer, address(multiverse)), 0);
        assertEq(genesisRep.nonces(signer), 0);
    }

    /* =============================================== WRAP ================================================== */

    function test_Wrap_PlainAllowanceStillPullsFromTheCaller() public {
        vm.prank(signer);
        underlying.approve(address(genesisRep), SIGNER_UNDERLYING);

        // The vault pulls from the caller directly, as before; nothing passes through the Multiverse.
        vm.expectEmit(true, true, true, true, address(genesisRep));
        emit ILituusRep.Wrapped(signer, 20 ether, 20 ether);
        vm.prank(signer);
        (uint256 assets, uint256 shares) = multiverse.wrap(GENESIS_UID, 20 ether, 0);

        assertEq(assets, 20 ether);
        assertEq(shares, 20 ether);
        assertEq(genesisRep.balanceOf(signer), SIGNER_REP + 20 ether);
        assertEq(underlying.balanceOf(signer), SIGNER_UNDERLYING - 20 ether);
        assertEq(underlying.balanceOf(address(multiverse)), 0);
    }

    function test_Wrap_ThroughPermit2_ExactAssets() public {
        (IPermit2.PermitSingle memory permitSingle, bytes memory signature) =
            _signerPermit2(address(underlying), uint160(SIGNER_UNDERLYING));
        uint256 vaultAssetsBefore = genesisRep.totalAssets();

        // The underlying passes through the Multiverse, which wraps it and hands the shares over.
        vm.expectEmit(true, true, true, true, address(genesisRep));
        emit ILituusRep.Wrapped(address(multiverse), 20 ether, 20 ether);
        _multicall(
            signer, _permit2Call(permitSingle, signature), abi.encodeCall(Multiverse.wrap, (GENESIS_UID, 20 ether, 0))
        );

        assertEq(genesisRep.balanceOf(signer), SIGNER_REP + 20 ether);
        assertEq(underlying.balanceOf(signer), SIGNER_UNDERLYING - 20 ether);
        assertEq(genesisRep.totalAssets(), vaultAssetsBefore + 20 ether);
        // Nothing sticks to the Multiverse on the way.
        assertEq(underlying.balanceOf(address(multiverse)), 0);
        assertEq(genesisRep.balanceOf(address(multiverse)), 0);
        assertEq(_permit2Allowance(address(underlying)), SIGNER_UNDERLYING - 20 ether);
    }

    function test_Wrap_ThroughPermit2_ExactSharesAtARateAboveOne() public {
        // A burn moves the rate, so the exact-shares path has to pull the rounded-up underlying the vault
        // itself computes, and nothing more.
        vm.prank(user);
        genesisRep.transfer(address(multiverse), 50 ether);
        vm.prank(address(multiverse));
        genesisRep.burnShares(50 ether);
        uint256 sharesWanted = 10 ether;
        uint256 assetsNeeded = genesisRep.convertToAssetsUp(sharesWanted);
        assertGt(assetsNeeded, sharesWanted);
        (IPermit2.PermitSingle memory permitSingle, bytes memory signature) =
            _signerPermit2(address(underlying), uint160(SIGNER_UNDERLYING));

        _multicall(
            signer,
            _permit2Call(permitSingle, signature),
            abi.encodeCall(Multiverse.wrap, (GENESIS_UID, 0, sharesWanted))
        );

        assertEq(genesisRep.balanceOf(signer), SIGNER_REP + sharesWanted);
        assertEq(underlying.balanceOf(signer), SIGNER_UNDERLYING - assetsNeeded);
        assertEq(underlying.balanceOf(address(multiverse)), 0);
        assertEq(genesisRep.balanceOf(address(multiverse)), 0);
    }

    function test_RevertWhen_Wrap_NoAllowanceAnywhere() public {
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(AllowanceExpired.selector, 0));
        multiverse.wrap(GENESIS_UID, 20 ether, 0);
    }

    /* ============================================ CONSTRUCTOR ============================================== */

    function test_RevertWhen_Permit2HasNoCode() public {
        vm.expectRevert(PermitSupport.InvalidPermit2.selector);
        new Multiverse(
            zoltar,
            GENESIS_UID,
            feeCtl,
            queryTokenizerStub,
            tokenDeployer,
            IPermit2(stranger),
            MIGRATION_DURATION,
            REPORTING_PERIOD,
            APPEAL_PERIOD
        );
    }

    function test_Constructor_SetsPermit2() public view {
        assertEq(address(multiverse.PERMIT2()), address(permit2));
        assertGt(address(permit2).code.length, 0);
    }
}
