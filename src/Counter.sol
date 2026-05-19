// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title  Counter
/// @notice Minimal counter demonstrating template patterns: OZ integration,
///         custom errors, indexed events, NatSpec, and bounded state.
contract Counter is Ownable {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Current counter value.
    uint256 public number;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Hard upper bound. Anything above reverts.
    uint256 public constant MAX_NUMBER = type(uint128).max;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when `number` is incremented by one.
    /// @param  by       Caller that triggered the increment.
    /// @param  newValue Value after the increment.
    event Incremented(address indexed by, uint256 newValue);

    /// @notice Emitted when `number` is set to an arbitrary value.
    /// @param  by       Caller that triggered the set.
    /// @param  newValue Value after the set.
    event NumberSet(address indexed by, uint256 newValue);

    /// @notice Emitted when `number` is reset to zero.
    /// @param  by Owner that triggered the reset.
    event Reset(address indexed by);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an operation would push `number` above MAX_NUMBER.
    error CounterOverflow();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param initialOwner Address granted exclusive reset rights.
    constructor(address initialOwner) Ownable(initialOwner) { }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL WRITES
    //////////////////////////////////////////////////////////////*/

    /// @notice Increment `number` by one.
    /// @dev Reverts with {CounterOverflow} if `number` already at MAX_NUMBER.
    function increment() external {
        if (number >= MAX_NUMBER) revert CounterOverflow();
        unchecked {
            ++number;
        }
        emit Incremented(msg.sender, number);
    }

    /// @notice Set `number` to a specific value.
    /// @param newNumber Target value, must be <= MAX_NUMBER.
    function setNumber(uint256 newNumber) external {
        if (newNumber > MAX_NUMBER) revert CounterOverflow();
        number = newNumber;
        emit NumberSet(msg.sender, newNumber);
    }

    /// @notice Reset the counter to zero. Owner-only.
    function reset() external onlyOwner {
        number = 0;
        emit Reset(msg.sender);
    }
}
