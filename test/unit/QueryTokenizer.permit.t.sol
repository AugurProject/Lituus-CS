// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Multiverse } from "src/Multiverse.sol";
import { PermitSupport } from "src/PermitSupport.sol";
import { QueryToken } from "src/QueryToken.sol";
import { QueryTokenizer } from "src/QueryTokenizer.sol";
import { IPermit2 } from "src/interfaces/IPermit2.sol";
import { QueryTokenizerFixtures } from "./QueryTokenizer.fixtures.sol";
import { PermitSigning } from "../utils/PermitSigning.sol";

/// @notice Minting query tokens in the same transaction that approves the tokenizer: an ERC-2612 permit on wREP
///         relayed through permitRep, or a Permit2 allowance relayed through permit2, each followed by mint in
///         one multicall. The query token itself carries ERC-2612 permits for whoever trades it.
contract QueryTokenizerPermitTest is QueryTokenizerFixtures, PermitSigning {
    uint256 internal constant SIGNER_REP = 100 ether;

    address internal signer;
    uint256 internal signerKey;
    address internal stranger;
    uint256 internal strangerKey;

    function setUp() public override {
        super.setUp();
        (signer, signerKey) = makeAddrAndKey("signer");
        (stranger, strangerKey) = makeAddrAndKey("stranger");
        _fundWithRep(signer, SIGNER_REP);
        // The funding helper approves the Multiverse, never the tokenizer: the signer starts with no allowance
        // to the tokenizer of any kind.
        assertEq(genesisRep.allowance(signer, address(tokenizer)), 0);
    }

    function _mintCall(uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(QueryTokenizer.mint, (GENESIS_UID, amount));
    }

    function _multicall(address caller, bytes memory first, bytes memory second) internal {
        bytes[] memory calls = new bytes[](2);
        calls[0] = first;
        calls[1] = second;
        vm.prank(caller);
        tokenizer.multicall(calls);
    }

    function _signerPermit2(uint160 amount)
        internal
        returns (IPermit2.PermitSingle memory permitSingle, bytes memory signature)
    {
        vm.prank(signer);
        genesisRep.approve(address(permit2), type(uint256).max);
        permitSingle = _permitSingle(permit2, signer, address(genesisRep), amount, address(tokenizer));
        signature = _signPermit2(permit2, signerKey, permitSingle);
    }

    function test_PermitRep_ThenMintInOneTransaction() public {
        uint256 cost = tokenizer.mintPrice(GENESIS_UID) * 2;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(genesisRep, signerKey, address(tokenizer), cost, deadline);

        _multicall(
            signer, abi.encodeCall(QueryTokenizer.permitRep, (GENESIS_UID, cost, deadline, v, r, s)), _mintCall(2)
        );

        assertEq(tokenizer.token(GENESIS_UID).balanceOf(signer), 2 * tokenizer.ONE_QUERY());
        assertEq(tokenizer.pooledRep(GENESIS_UID), cost);
        assertEq(genesisRep.balanceOf(signer), SIGNER_REP - cost);
        assertEq(genesisRep.allowance(signer, address(tokenizer)), 0);
    }

    function test_PermitRep_GoesThroughWhenSomeoneSubmittedThePermitFirst() public {
        uint256 cost = tokenizer.mintPrice(GENESIS_UID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(genesisRep, signerKey, address(tokenizer), cost, deadline);
        vm.prank(stranger);
        genesisRep.permit(signer, address(tokenizer), cost, deadline, v, r, s);

        _multicall(
            signer, abi.encodeCall(QueryTokenizer.permitRep, (GENESIS_UID, cost, deadline, v, r, s)), _mintCall(1)
        );

        assertEq(tokenizer.token(GENESIS_UID).balanceOf(signer), tokenizer.ONE_QUERY());
    }

    function test_RevertWhen_PermitRep_Expired() public {
        uint256 cost = tokenizer.mintPrice(GENESIS_UID);
        uint256 deadline = vm.getBlockTimestamp() - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(genesisRep, signerKey, address(tokenizer), cost, deadline);

        vm.prank(signer);
        vm.expectRevert(PermitSupport.PermitNotEffective.selector);
        tokenizer.permitRep(GENESIS_UID, cost, deadline, v, r, s);
    }

    function test_RevertWhen_PermitRep_UniverseNotExisting() public {
        vm.prank(signer);
        vm.expectRevert(Multiverse.InvalidUniverse.selector);
        tokenizer.permitRep(GENESIS_UID + 1, 1 ether, vm.getBlockTimestamp() + 1 hours, 27, bytes32(0), bytes32(0));
    }

    function test_Permit2_ThenMintInOneTransaction() public {
        uint256 cost = tokenizer.mintPrice(GENESIS_UID) * 3;
        (IPermit2.PermitSingle memory permitSingle, bytes memory signature) = _signerPermit2(uint160(cost));

        _multicall(signer, abi.encodeCall(PermitSupport.permit2, (permitSingle, signature)), _mintCall(3));

        assertEq(tokenizer.token(GENESIS_UID).balanceOf(signer), 3 * tokenizer.ONE_QUERY());
        assertEq(genesisRep.balanceOf(signer), SIGNER_REP - cost);
        assertEq(genesisRep.balanceOf(address(tokenizer)), cost);
        (uint160 left,,) = permit2.allowance(signer, address(genesisRep), address(tokenizer));
        assertEq(left, 0);
    }

    function test_RevertWhen_Mint_NoAllowanceAnywhere() public {
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(AllowanceExpired.selector, 0));
        tokenizer.mint(GENESIS_UID, 1);
    }

    function test_QueryToken_PermitWorksForHolders() public {
        _mintTokens(user, 1);
        QueryToken queryToken = _genesisQueryToken();
        uint256 oneQuery = tokenizer.ONE_QUERY();
        (address holder, uint256 holderKey) = makeAddrAndKey("holder");
        vm.prank(user);
        assertTrue(queryToken.transfer(holder, oneQuery));

        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(queryToken, holderKey, stranger, oneQuery, deadline);
        vm.prank(stranger);
        queryToken.permit(holder, stranger, oneQuery, deadline, v, r, s);

        assertEq(queryToken.allowance(holder, stranger), oneQuery);
        assertEq(queryToken.nonces(holder), 1);
        vm.prank(stranger);
        assertTrue(queryToken.transferFrom(holder, stranger, oneQuery));
        assertEq(queryToken.balanceOf(stranger), oneQuery);
    }

    function test_RevertWhen_Permit2HasNoCode() public {
        vm.expectRevert(PermitSupport.InvalidPermit2.selector);
        new QueryTokenizer(IPermit2(stranger));
    }
}
