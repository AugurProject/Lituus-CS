// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";

import { LituusRep } from "../../src/LituusRep.sol";
import { MockERC20 } from "../../src/mock/MockERC20.sol";

/// @notice Fuzzed properties of the LituusRep vault, driven by random operation sequences with the
///         test contract as the owner: the rate is monotone and moves only on burns, the ceiling
///         conversions stay within one wei of the floor views, and the vault stays solvent against
///         the outstanding share liability after any sequence.
contract LituusRepFuzzTest is Test {
    MockERC20 internal underlying;
    LituusRep internal vault;

    address internal alice = makeAddr("alice");

    function setUp() public {
        underlying = new MockERC20("Reputation", "REP");
        vault = new LituusRep(address(this), address(underlying), "Lituus Reputation Token", "wREP", 1 ether);

        underlying.mint(alice, 1000 ether);
        vm.prank(alice);
        underlying.approve(address(vault), type(uint256).max);
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
