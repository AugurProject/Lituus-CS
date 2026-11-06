// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Test } from "forge-std/Test.sol";

import { LituusRep } from "src/LituusRep.sol";
import { QueryToken } from "src/QueryToken.sol";
import { TokenDeployer } from "src/TokenDeployer.sol";
import { IZoltarRepToken } from "src/interfaces/IZoltarRepToken.sol";
import { MockERC20 } from "src/mock/MockERC20.sol";
import { MockZoltarRepToken } from "src/mock/MockZoltarRepToken.sol";

/// @notice TokenDeployer in isolation: vaults belong to the Multiverse it serves and query tokens to that
///         Multiverse's QueryTokenizer (this test stands in for both), nobody else gets either, and both are named
///         after the Zoltar REP token's repNumber, with 0 for a token whose repNumber call reverts (the genesis
///         REPv2). A token that cannot answer at all (no code, malformed return) reverts the deployment.
contract TokenDeployerTest is Test {
    TokenDeployer internal tokenDeployer;
    address internal caller = makeAddr("caller");
    // What this test, as the Multiverse, reports as its QueryTokenizer: itself unless a test says otherwise.
    address internal queryTokenizer = address(this);

    /// @dev Bound to this test contract, which plays the Multiverse.
    function setUp() public {
        tokenDeployer = new TokenDeployer(address(this));
    }

    /// @dev The Multiverse's QueryTokenizer getter, which the deployer reads to authorize query tokens.
    function QUERY_TOKENIZER() external view returns (address) {
        return queryTokenizer;
    }

    /// @dev Deploys both token kinds over `zoltarRepToken` and checks they carry `expectedNumber`.
    function _assertNaming(address zoltarRepToken, string memory expectedNumber) internal {
        address vault = address(tokenDeployer.deployLituusRep(zoltarRepToken, 1 ether));
        assertEq(IERC20Metadata(vault).name(), string.concat("Lituus Reputation Token ", expectedNumber));
        assertEq(IERC20Metadata(vault).symbol(), string.concat("wREP", expectedNumber));
        address queryToken = address(tokenDeployer.deployQueryToken(zoltarRepToken));
        assertEq(IERC20Metadata(queryToken).name(), string.concat("Lituus Query Token ", expectedNumber));
        assertEq(IERC20Metadata(queryToken).symbol(), string.concat("QT", expectedNumber));
    }

    /* ================================================ OWNERSHIP =============================================== */

    function test_DeployLituusRep_BelongsToTheMultiverse() public {
        MockZoltarRepToken zoltarRep = new MockZoltarRepToken(1);
        address predicted = vm.computeCreateAddress(address(tokenDeployer), vm.getNonce(address(tokenDeployer)));
        vm.expectEmit(true, true, true, true, address(tokenDeployer));
        emit TokenDeployer.LituusRepDeployed(address(zoltarRep), predicted);
        LituusRep vault = LituusRep(address(tokenDeployer.deployLituusRep(address(zoltarRep), 2 ether)));

        assertEq(address(vault), predicted);
        assertEq(vault.owner(), address(this));
        assertEq(address(vault.UNDERLYING_TOKEN()), address(zoltarRep));
        assertEq(vault.rate(), 2 ether);
    }

    function test_DeployQueryToken_BelongsToTheQueryTokenizer() public {
        queryTokenizer = caller;
        MockZoltarRepToken zoltarRep = new MockZoltarRepToken(1);
        address predicted = vm.computeCreateAddress(address(tokenDeployer), vm.getNonce(address(tokenDeployer)));
        vm.prank(caller);
        QueryToken queryToken = QueryToken(address(tokenDeployer.deployQueryToken(address(zoltarRep))));

        assertEq(address(queryToken), predicted);
        assertEq(queryToken.owner(), caller);
        assertEq(queryToken.totalSupply(), 0);
    }

    /* ================================================= ACCESS ================================================= */

    // A vault from anyone but the Multiverse is covered in Multiverse.constructor.t.sol
    // (test_RevertWhen_TokenDeployer_CallerIsNotTheMultiverse).

    function test_RevertWhen_DeployQueryToken_CallerIsNotTheQueryTokenizer() public {
        address zoltarRep = address(new MockZoltarRepToken(1));
        vm.prank(caller);
        vm.expectRevert(TokenDeployer.NotQueryTokenizer.selector);
        tokenDeployer.deployQueryToken(zoltarRep);
    }

    /// @dev Being the Multiverse is not enough: query tokens go to its QueryTokenizer only.
    function test_RevertWhen_DeployQueryToken_CallerIsTheMultiverse() public {
        // Change this contract's QueryTokenizer to a different address, so the Multiverse (this contract) is not the
        // tokenizer.
        queryTokenizer = makeAddr("queryTokenizer");
        address zoltarRep = address(new MockZoltarRepToken(1));
        vm.expectRevert(TokenDeployer.NotQueryTokenizer.selector);
        // called by Multiverse, but not its QueryTokenizer
        tokenDeployer.deployQueryToken(zoltarRep);
    }

    /* ============================================ NUMBERED TOKENS ============================================= */

    function test_Naming_FirstChild() public {
        _assertNaming(address(new MockZoltarRepToken(1)), "1");
    }

    function test_Naming_MultiDigit() public {
        _assertNaming(address(new MockZoltarRepToken(10)), "10");
        _assertNaming(address(new MockZoltarRepToken(1234)), "1234");
    }

    function test_Naming_MaxRepNumber() public {
        _assertNaming(
            address(new MockZoltarRepToken(type(uint256).max)),
            "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        );
    }

    /// @dev The suffix is exactly Zoltar's own: the vault's symbol is "w" + the Zoltar REP symbol.
    function testFuzz_Naming_MatchesZoltarSuffix(uint256 repNumber) public {
        repNumber = bound(repNumber, 1, type(uint256).max);
        MockZoltarRepToken zoltarRep = new MockZoltarRepToken(repNumber);
        _assertNaming(address(zoltarRep), vm.toString(repNumber));
        address vault = address(tokenDeployer.deployLituusRep(address(zoltarRep), 1 ether));
        assertEq(IERC20Metadata(vault).symbol(), string.concat("w", zoltarRep.symbol()));
    }

    /* ========================================= GENESIS AND REJECTIONS ========================================= */

    /// @dev The genesis REPv2 has no repNumber (mainnet: the call reverts with empty data), so it takes 0.
    function test_Naming_GenesisWithoutRepNumber() public {
        _assertNaming(address(new MockERC20("Reputation", "REPv2")), "0");
    }

    /// @dev Any revert counts as "no repNumber" (0), with or without revert data (mainnet REPv2 reverts with none).
    function test_Naming_RevertingRepNumber() public {
        address token = makeAddr("reverting");
        vm.mockCallRevert(token, abi.encodeCall(IZoltarRepToken.repNumber, ()), "nope");
        _assertNaming(token, "0");
    }

    /// @dev A call to an address without code succeeds with empty return data, and decoding it reverts outside the
    ///      try: no token is named after an address that is not a token.
    function test_RevertWhen_NoCode() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert();
        tokenDeployer.deployLituusRep(eoa, 1 ether);
        vm.expectRevert();
        tokenDeployer.deployQueryToken(eoa);
    }

    /// @dev A malformed (short) return fails to decode outside the try and reverts the deployment.
    function test_RevertWhen_ShortReturnData() public {
        address token = makeAddr("short");
        vm.mockCall(token, abi.encodeCall(IZoltarRepToken.repNumber, ()), hex"07");
        vm.expectRevert();
        tokenDeployer.deployLituusRep(token, 1 ether);
        vm.expectRevert();
        tokenDeployer.deployQueryToken(token);
    }
}
