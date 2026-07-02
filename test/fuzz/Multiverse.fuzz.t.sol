// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";

import { Multiverse } from "src/Multiverse.sol";
import { ILituusRep } from "src/interfaces/ILituusRep.sol";
import { IReputationToken } from "src/interfaces/IReputationToken.sol";
import { MockERC20 } from "src/mock/MockERC20.sol";
import { MockZoltar } from "src/mock/MockZoltar.sol";
import { MockQueryFeeController } from "src/mock/MockQueryFeeController.sol";

/// @notice Property-based tests for createQuery. The fuzzer throws random inputs at the assumptions.
contract MultiverseFuzzTest is Test {
    uint248 internal constant GENESIS_UID = 0;
    uint256 internal constant DEFAULT_FEE = 1 ether;
    uint256 internal constant USER_REP_BALANCE = 1000 ether;

    MockERC20 internal underlying;
    MockZoltar internal zoltar;
    MockQueryFeeController internal feeCtl;
    Multiverse internal multiverse;
    ILituusRep internal genesisRep;

    address internal user = makeAddr("user");

    function setUp() public {
        underlying = new MockERC20("Underlying", "U");
        zoltar = new MockZoltar(IReputationToken(address(underlying)));
        feeCtl = new MockQueryFeeController(DEFAULT_FEE);
        multiverse = new Multiverse(zoltar, GENESIS_UID, feeCtl);

        (ILituusRep repToken,,,,,,,,,) = multiverse.universes(GENESIS_UID);
        genesisRep = repToken;

        underlying.mint(user, USER_REP_BALANCE);
        vm.startPrank(user);
        underlying.approve(address(genesisRep), type(uint256).max);
        multiverse.wrap(GENESIS_UID, USER_REP_BALANCE);
        genesisRep.approve(address(multiverse), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Property: any outcome count in [MIN_OUTCOMES, MAX_OUTCOMES] is stored as given.
    function testFuzz_CreateQuery_ValidOutcomes(uint8 n) public {
        n = uint8(bound(uint256(n), multiverse.MIN_OUTCOMES(), multiverse.MAX_OUTCOMES()));

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", n);

        (uint8 numberOfOutcomes,,,) = multiverse.queries(0);
        assertEq(numberOfOutcomes, n);
        assertEq(multiverse.queryCount(), 1);
    }

    /// @dev Property: outcome counts below MIN_OUTCOMES always revert.
    function testFuzz_CreateQuery_RevertsLowOutcomes(uint8 n) public {
        n = uint8(bound(uint256(n), 0, uint256(multiverse.MIN_OUTCOMES()) - 1));

        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidNumberOfOutcomes.selector);
        multiverse.createQuery(GENESIS_UID, "q", n);
    }

    /// @dev Property: outcome counts above MAX_OUTCOMES always revert.
    /// This test is added for clarity but has only one input value (255) that is above MAX_OUTCOMES.
    /// It might become useful if MAX_OUTCOMES is ever changed to a lower value.
    function testFuzz_CreateQuery_RevertsHighOutcomes(uint8 n) public {
        n = uint8(bound(uint256(n), uint256(multiverse.MAX_OUTCOMES()) + 1, 255));

        vm.prank(user);
        vm.expectRevert(Multiverse.InvalidNumberOfOutcomes.selector);
        multiverse.createQuery(GENESIS_UID, "q", n);
    }

    /// @dev Property: the exact fee reported by the controller is charged and stored.
    function testFuzz_CreateQuery_VaryingFee(uint256 fee) public {
        fee = bound(fee, 0, USER_REP_BALANCE);
        feeCtl.setFee(fee);
        uint256 userBalanceBefore = genesisRep.balanceOf(user);

        vm.prank(user);
        multiverse.createQuery(GENESIS_UID, "q", 3);

        (,, uint256 storedFee,) = multiverse.queries(0);
        assertEq(storedFee, fee);
        assertEq(genesisRep.balanceOf(address(multiverse)), fee);
        assertEq(genesisRep.balanceOf(user), userBalanceBefore - fee);
    }
}
