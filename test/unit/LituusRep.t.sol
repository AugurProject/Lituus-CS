// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";

import { LituusRep } from "../../src/LituusRep.sol";
import { MockERC20 } from "../../src/mock/MockERC20.sol";

/// @notice Sanity and property checks of the LituusRep vault mechanics, exercised directly with
///         the test contract as the owner: round trips in every declaration mode, the burn-driven
///         rate movement, rounding directions, ledger inertia, dust socialization, the pause
///         switch, and fuzzed rate/solvency invariants.
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

    /* ================================================ UNIT TESTS =============================================== */

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
        LituusRep child =
            new LituusRep(address(this), address(underlying), "Lituus Reputation Token", "wREP", 1.25 ether);
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

    /// @dev wrapShares pulls the underlying rounded UP: the caller fixes the shares and pays the
    ///      ceiling of their value, visible at wei scale where the floor and ceil differ.
    function test_WrapShares_PullsCeilAssets() public {
        vault.wrap(alice, 100 ether);
        vm.prank(alice);
        vault.transfer(address(this), 20 ether);
        vault.burnShares(20 ether);
        assertEq(vault.rate(), 1.25 ether);

        // 30 shares cost exactly 37.5 REP at 1.25 - no rounding needed.
        uint256 balanceBefore = underlying.balanceOf(bob);
        assertEq(vault.wrapShares(bob, 30 ether), 37.5 ether);
        assertEq(underlying.balanceOf(bob), balanceBefore - 37.5 ether);
        assertEq(vault.balanceOf(bob), 30 ether);

        // 3 wei of shares are worth 3.75 wei: the vault charges 4 (up), the floor view says 3.
        assertEq(vault.convertToAssets(3), 3);
        assertEq(vault.wrapShares(bob, 3), 4);
    }

    /// @dev unwrapAssets burns shares rounded UP: the caller fixes the underlying received and
    ///      surrenders the ceiling of the shares it is worth.
    function test_UnwrapAssets_BurnsCeilShares() public {
        vault.wrap(alice, 100 ether);
        vm.prank(alice);
        vault.transfer(address(this), 20 ether);
        vault.burnShares(20 ether);

        vault.wrap(bob, 100 ether); // 80 shares at 1.25

        // 30 REP costs exactly 24 shares at 1.25.
        assertEq(vault.unwrapAssets(bob, 30 ether), 24 ether);
        assertEq(vault.balanceOf(bob), 56 ether);

        // 1 wei of underlying is worth 0.8 wei of shares: the floor view says 0, the vault burns 1.
        assertEq(vault.convertToShares(1), 0);
        assertEq(vault.unwrapAssets(bob, 1), 1);
    }

    /// @dev No round trip through any pair of wrap/unwrap declaration modes ever returns more than
    ///      it took: at an awkward rate (10/7) every remainder stays with the vault.
    function test_RoundTrip_NeverProfitable() public {
        vault.wrap(alice, 100 ether);
        vm.prank(alice);
        vault.transfer(address(this), 30 ether);
        vault.burnShares(30 ether); // rate = 100/70 = 1.428571... (floored at 1e18 scale)

        // wrap -> unwrap: 1 REP in, 999999999999999999 back; 1 wei stays.
        uint256 shares = vault.wrap(bob, 1 ether);
        assertEq(shares, 0.7 ether);
        assertEq(vault.unwrap(bob, shares), 1 ether - 1);

        // wrapShares -> unwrap on the same share amount: pays 8, gets 7 back.
        uint256 paid = vault.wrapShares(bob, 5);
        assertEq(paid, 8);
        assertEq(vault.unwrap(bob, 5), 7);

        // Cross pair on the same underlying amount: providing 1 REP mints 0.7e18 shares, while
        // receiving 1 REP back burns one share-wei more. Wrap 2 REP so the balance covers the
        // ceiling.
        uint256 minted = vault.wrap(bob, 2 ether);
        uint256 burned = vault.unwrapAssets(bob, 1 ether);
        assertEq(minted, 1.4 ether);
        assertEq(burned, 0.7 ether + 1);
    }

    /// @dev Assets are tracked in an internal ledger: underlying sent directly to the vault does
    ///      not move the rate, the ledger, or any conversion.
    function test_DonationIsInert() public {
        vault.wrap(alice, 100 ether);
        vm.prank(alice);
        vault.transfer(address(this), 20 ether);
        vault.burnShares(20 ether);

        underlying.mint(address(vault), 500 ether);

        assertEq(vault.rate(), 1.25 ether);
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(vault.convertToShares(100 ether), 80 ether);
        assertEq(vault.convertToAssets(80 ether), 100 ether);
        assertEq(vault.wrap(bob, 100 ether), 80 ether);
    }

    /// @dev Rounding remainders retained by the vault fold into the rate at the next burnShares.
    ///      Wei-scale scenario so the socialization is exactly measurable: bob's round trip leaves
    ///      1 wei behind, and the recompute lands on 2.02 instead of the 2.00 baseline.
    function test_Dust_SocializedAtNextBurn() public {
        vault.wrap(alice, 100); // 100 wei
        vm.prank(alice);
        vault.transfer(address(this), 30);
        vault.burnShares(30); // rate = 100/70 at 1e18 scale

        // Bob wraps 10 wei (7 shares floored), unwraps the 7 shares (9 wei floored): 1 wei stays.
        assertEq(vault.wrap(bob, 10), 7);
        assertEq(vault.unwrap(bob, 7), 9);
        assertEq(vault.totalAssets(), 101);

        // The next burn folds the retained wei into the rate: 101 * SCALE / 50 = 2.02, where the
        // dust-free baseline (100 * SCALE / 50) is 2.00.
        vm.prank(alice);
        vault.transfer(address(this), 20);
        vault.burnShares(20);
        assertEq(vault.rate(), 2.02 ether);
    }

    /// @dev Every declaration mode rejects amounts that would round or resolve to nothing.
    function test_ZeroAmountGuards() public {
        vault.wrap(alice, 100 ether);
        vm.prank(alice);
        vault.transfer(address(this), 50 ether);
        vault.burnShares(50 ether);
        assertEq(vault.rate(), 2 ether);

        // 1 wei of underlying floors to 0 shares at rate 2: the wrap would be a donation.
        vm.expectRevert(LituusRep.ZeroShares.selector);
        vault.wrap(alice, 1);

        vm.expectRevert(LituusRep.ZeroShares.selector);
        vault.wrapShares(alice, 0);

        vm.expectRevert(LituusRep.ZeroAssets.selector);
        vault.unwrap(alice, 0);

        vm.expectRevert(LituusRep.ZeroAssets.selector);
        vault.unwrapAssets(alice, 0);
    }

    /// @dev The exposed ceiling views mirror the floor views by at most one wei and match what
    ///      the exact-output functions actually pull and burn.
    function test_ConvertUpViews_MirrorFloorViews() public {
        vault.wrap(alice, 100 ether);
        vm.prank(alice);
        vault.transfer(address(this), 30 ether);
        vault.burnShares(30 ether); // rate = 100/70

        // Exact division: up equals down.
        assertEq(vault.convertToAssets(7 ether), vault.convertToAssetsUp(7 ether));

        // Non-exact: up is exactly one wei above down, and matches the mutating paths.
        assertEq(vault.convertToShares(10), 7);
        assertEq(vault.convertToSharesUp(10), 8);
        uint256 expected = vault.convertToSharesUp(1 ether);
        assertEq(expected, 0.7 ether + 1);
        assertEq(vault.unwrapAssets(alice, 1 ether), expected);
    }

    /* =============================================== FUZZ HELPERS ============================================== */

    /// @dev Applies one pseudo-random vault operation derived from `word`, guarded so it never
    ///      reverts: op 0-3 are the four wrap/unwrap modes on alice, op 4 transfers shares to the
    ///      owner and burns them. Returns whether the operation was a burn.
    function _applyRandomOp(uint256 word) internal returns (bool wasBurn) {
        uint256 op = word % 5;
        uint256 amount = word >> 8;

        if (op == 0) {
            uint256 maxAssets = underlying.balanceOf(alice);
            if (maxAssets == 0) return false;
            amount = bound(amount, 1, maxAssets < 1e21 ? maxAssets : 1e21);
            if (vault.convertToShares(amount) == 0) return false;
            vault.wrap(alice, amount);
        } else if (op == 1) {
            uint256 maxShares = vault.convertToShares(underlying.balanceOf(alice));
            if (maxShares == 0) return false;
            amount = bound(amount, 1, maxShares < 1e21 ? maxShares : 1e21);
            vault.wrapShares(alice, amount);
        } else if (op == 2) {
            uint256 shareBalance = vault.balanceOf(alice);
            if (shareBalance == 0) return false;
            amount = bound(amount, 1, shareBalance);
            if (vault.convertToAssets(amount) == 0) return false;
            vault.unwrap(alice, amount);
        } else if (op == 3) {
            uint256 maxOut = vault.convertToAssets(vault.balanceOf(alice));
            if (maxOut == 0) return false;
            amount = bound(amount, 1, maxOut);
            vault.unwrapAssets(alice, amount);
        } else {
            uint256 shareBalance = vault.balanceOf(alice);
            if (shareBalance == 0) return false;
            amount = bound(amount, 1, shareBalance);
            vm.prank(alice);
            vault.transfer(address(this), amount);
            vault.burnShares(amount);
            return true;
        }
        return false;
    }

    /* ================================================ FUZZ TESTS =============================================== */

    /// @dev Across any operation sequence the rate never decreases, and it only ever changes on a
    ///      burn step - wraps and unwraps in every declaration mode are rate-neutral.
    function testFuzz_RateMonotoneOnlyOnBurn(uint256 seed) public {
        underlying.mint(alice, 1e30);
        vault.wrap(alice, 100 ether);

        for (uint256 i = 0; i < 15; i++) {
            uint256 rateBefore = vault.rate();
            bool wasBurn = _applyRandomOp(uint256(keccak256(abi.encode(seed, i))));
            assertGe(vault.rate(), rateBefore);
            if (!wasBurn) {
                assertEq(vault.rate(), rateBefore);
            }
        }
    }

    /// @dev The ceiling conversions exceed the floor views by at most one wei, at any rate: a
    ///      wrong rounding direction anywhere would blow this bound open.
    function testFuzz_ConversionPairTight(uint256 shares, uint256 assets, uint256 burnAmount) public {
        underlying.mint(alice, 1e30);
        vault.wrap(alice, 100 ether);
        burnAmount = bound(burnAmount, 0, 99 ether);
        if (burnAmount > 0) {
            vm.prank(alice);
            vault.transfer(address(this), burnAmount);
            vault.burnShares(burnAmount);
        }

        // Fixing shares: the assets pulled (ceil) vs the floor view of the same share amount.
        shares = bound(shares, 1, 1e24);
        uint256 pulled = vault.wrapShares(alice, shares);
        assertLe(pulled - vault.convertToAssets(shares), 1);

        // Fixing assets: the shares burned (ceil) vs the floor view of the same asset amount.
        uint256 maxOut = vault.convertToAssets(vault.balanceOf(alice));
        assets = bound(assets, 1, maxOut);
        uint256 burned = vault.unwrapAssets(alice, assets);
        assertLe(burned - vault.convertToShares(assets), 1);
    }

    /// @dev After any operation sequence the vault can always pay every share at the stored rate:
    ///      totalAssets covers the ceiling of the outstanding liability, so the last unwrapper is
    ///      never short.
    function testFuzz_Solvency(uint256 seed) public {
        underlying.mint(alice, 1e30);
        vault.wrap(alice, 100 ether);

        for (uint256 i = 0; i < 15; i++) {
            _applyRandomOp(uint256(keccak256(abi.encode(seed, i))));
            uint256 liability = (vault.totalSupply() * vault.rate() + 1 ether - 1) / 1 ether;
            assertGe(vault.totalAssets(), liability);
        }
    }
}
