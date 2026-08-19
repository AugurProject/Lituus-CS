// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";

import { LituusRep } from "../../src/LituusRep.sol";
import { MockERC20 } from "../../src/mock/MockERC20.sol";

/// @notice Basic sanity checks of the LituusRep vault mechanics, exercised directly with the test
///         contract as the owner: the genesis 1:1 round trip, the burn-driven rate movement with
///         its effect on every conversion direction, and the unwrap pause switch.
contract LituusRepTest is Test {
    MockERC20 internal underlying;
    LituusRep internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        underlying = new MockERC20("Reputation", "REP");
        vault = new LituusRep(address(this), address(underlying), "Lituus Reputation Token", "wREP", 1 ether);

        underlying.mint(alice, 1000 ether);
        underlying.mint(bob, 1000 ether);
        vm.prank(alice);
        underlying.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        underlying.approve(address(vault), type(uint256).max);
    }

    /// @dev At the genesis 1:1 rate every conversion is the identity: wrapping and unwrapping in
    ///      either declaration mode moves exactly the stated amounts, and the ledger follows.
    function test_WrapUnwrap_RoundTripAtGenesisRate() public {
        assertEq(vault.rate(), 1 ether);

        uint256 shares = vault.wrap(alice, 100 ether);
        assertEq(shares, 100 ether);
        assertEq(vault.balanceOf(alice), 100 ether);
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(underlying.balanceOf(alice), 900 ether);

        uint256 assetsIn = vault.wrapShares(bob, 40 ether);
        assertEq(assetsIn, 40 ether);
        assertEq(vault.balanceOf(bob), 40 ether);
        assertEq(vault.totalAssets(), 140 ether);

        uint256 assetsOut = vault.unwrap(alice, 60 ether);
        assertEq(assetsOut, 60 ether);
        uint256 sharesBurned = vault.unwrapAssets(bob, 40 ether);
        assertEq(sharesBurned, 40 ether);

        assertEq(vault.balanceOf(alice), 40 ether);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.totalAssets(), 40 ether);
        assertEq(underlying.balanceOf(bob), 1000 ether);
        assertEq(vault.rate(), 1 ether);
    }

    /// @dev burnShares is the only rate-moving operation: burning 20 of 100 shares against 100
    ///      assets sets the rate to 1.25, after which wrapping 100 REP mints 80 shares, those 80
    ///      shares redeem the full 100 REP, and the rate survives the vault emptying out.
    function test_BurnShares_RaisesRateAndRepricesConversions() public {
        vault.wrap(alice, 100 ether);
        vm.prank(alice);
        vault.transfer(address(this), 20 ether);

        vault.burnShares(20 ether);

        assertEq(vault.rate(), 1.25 ether);
        assertEq(vault.totalSupply(), 80 ether);
        assertEq(vault.totalAssets(), 100 ether);

        assertEq(vault.wrap(bob, 100 ether), 80 ether);
        assertEq(vault.unwrap(bob, 80 ether), 100 ether);

        // Alice exits with appreciation: her remaining 80 shares redeem the whole 100 REP she
        // wrapped, and the emptied vault keeps the 1.25 rate for the next wrapper.
        assertEq(vault.unwrap(alice, 80 ether), 100 ether);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.rate(), 1.25 ether);
        assertEq(vault.wrap(bob, 100 ether), 80 ether);
    }

    /// @dev A vault constructed with an inherited rate converts at that rate from its first wrap,
    ///      and a zero rate is rejected: the child-universe spawning path can never mint at 1:1 by
    ///      accident.
    function test_Constructor_InitialRateIsRespected() public {
        LituusRep child = new LituusRep(address(this), address(underlying), "Lituus Reputation Token", "wREP", 1.25 ether);
        assertEq(child.rate(), 1.25 ether);

        vm.prank(alice);
        underlying.approve(address(child), type(uint256).max);
        assertEq(child.wrap(alice, 100 ether), 80 ether);

        vm.expectRevert(LituusRep.ZeroRate.selector);
        new LituusRep(address(this), address(underlying), "Lituus Reputation Token", "wREP", 0);
    }

    /// @dev The pause switch blocks both unwrap declaration modes and nothing else; unpausing
    ///      restores them.
    function test_SetUnwrapPaused_BlocksBothUnwrapPaths() public {
        vault.wrap(alice, 100 ether);
        vault.setUnwrapPaused(true);

        vm.expectRevert(LituusRep.UnwrapIsPaused.selector);
        vault.unwrap(alice, 10 ether);
        vm.expectRevert(LituusRep.UnwrapIsPaused.selector);
        vault.unwrapAssets(alice, 10 ether);

        // Wrapping stays open while unwrapping is paused.
        assertEq(vault.wrap(alice, 10 ether), 10 ether);

        vault.setUnwrapPaused(false);
        assertEq(vault.unwrap(alice, 10 ether), 10 ether);
    }
}
