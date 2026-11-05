// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Multicall } from "@openzeppelin/contracts/utils/Multicall.sol";

import { IPermit2 } from "./interfaces/IPermit2.sol";

/// @notice Lets a caller fund an action in the same transaction that authorizes it: an ERC-2612 permit on one
///         of our own tokens, or a Permit2 allowance for any token, Zoltar REP included. Meant to be used
///         through `multicall`, [permit, action]. Every pull takes a plain allowance first, so callers who
///         approve the old way see no change.
abstract contract PermitSupport is Multicall {
    using SafeERC20 for IERC20;

    /// @notice Uniswap's Permit2, the same contract on every chain.
    IPermit2 public immutable PERMIT2;

    /// @notice The permit left the caller's allowance to this contract short of what it asked for.
    error PermitNotEffective();
    error InvalidPermit2();

    constructor(IPermit2 permit2_) {
        // A call into an address with no code returns nothing and reverts nothing, so a wrong Permit2 address
        // would make every Permit2 pull a silent no-op; refuse it at deploy time.
        if (address(permit2_).code.length == 0) revert InvalidPermit2();
        PERMIT2 = permit2_;
    }

    /// @notice Relays a Permit2 permit the caller signed, so it can sit in the same multicall as the action it
    ///         funds. The spender has to be this contract.
    /// @dev A permit somebody else already submitted (the nonce is spent, the allowance is in place) goes
    ///      through; anything that leaves the allowance short of the permitted amount reverts.
    /// @param permitSingle The allowance being granted: token, amount, expiration, nonce, spender, deadline.
    /// @param signature The caller's signature over `permitSingle`.
    function permit2(IPermit2.PermitSingle calldata permitSingle, bytes calldata signature) external {
        try PERMIT2.permit(msg.sender, permitSingle, signature) { } catch { }
        (uint160 amount,,) = PERMIT2.allowance(msg.sender, permitSingle.details.token, address(this));
        if (amount < permitSingle.details.amount) revert PermitNotEffective();
    }

    /// @dev Applies the caller's ERC-2612 permit for this contract on `token`. A permit somebody else already
    ///      submitted (the nonce is spent, the allowance is in place) goes through; anything that leaves the
    ///      allowance short of `value` reverts.
    function _permit(IERC20Permit token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        try token.permit(msg.sender, address(this), value, deadline, v, r, s) { } catch { }
        if (IERC20(address(token)).allowance(msg.sender, address(this)) < value) revert PermitNotEffective();
    }

    /// @dev Pulls `amount` of `token` from the caller: on the caller's plain allowance when it covers the
    ///      amount, through the caller's Permit2 allowance otherwise.
    function _pull(IERC20 token, uint256 amount) internal {
        if (token.allowance(msg.sender, address(this)) >= amount) {
            token.safeTransferFrom(msg.sender, address(this), amount);
        } else {
            // REP amounts stay far below uint160.
            // forge-lint: disable-next-line(unsafe-typecast)
            PERMIT2.transferFrom(msg.sender, address(this), uint160(amount), address(token));
        }
    }
}
