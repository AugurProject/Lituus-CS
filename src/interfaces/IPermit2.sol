// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

/// @notice The part of Uniswap's Permit2 (its AllowanceTransfer side) that Lituus uses: a signed, expiring
///         allowance per (owner, token, spender), and transfers drawn against it. One approval of Permit2 per
///         token replaces the approve-before-every-contract dance, for any ERC20, Zoltar REP included.
interface IPermit2 {
    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }

    /// @notice Sets the allowance `permitSingle` describes, authorized by `owner`'s signature over it.
    function permit(address owner, PermitSingle calldata permitSingle, bytes calldata signature) external;

    /// @notice Moves `amount` of `token` from `from` to `to`, drawing on `from`'s allowance to the caller.
    function transferFrom(address from, address to, uint160 amount, address token) external;

    /// @notice The allowance `user` granted `spender` over `token`.
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);

    /// @notice The EIP-712 domain separator permits are signed under.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
