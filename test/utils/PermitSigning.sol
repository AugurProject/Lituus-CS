// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import { IPermit2 } from "src/interfaces/IPermit2.sol";

/// @notice Signs ERC-2612 permits and Permit2 PermitSingle permits for test accounts with known keys.
abstract contract PermitSigning is Test {
    bytes32 internal constant ERC2612_PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant PERMIT2_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 internal constant PERMIT2_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    // Permit2's own errors, for expectRevert.
    error AllowanceExpired(uint256 deadline);
    error InsufficientAllowance(uint256 amount);
    error SignatureExpired(uint256 signatureDeadline);
    error InvalidNonce();
    error InvalidSigner();

    /// @dev Signs an ERC-2612 permit by `key` (the owner's key) for `spender` on `token`, at the owner's
    ///      current nonce.
    function _signPermit(IERC20Permit token, uint256 key, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address owner = vm.addr(key);
        bytes32 structHash =
            keccak256(abi.encode(ERC2612_PERMIT_TYPEHASH, owner, spender, value, token.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(key, digest);
    }

    /// @dev A PermitSingle granting `spender` `amount` of `token` for a day, signed within the hour, at the
    ///      owner's current Permit2 nonce for that (token, spender).
    function _permitSingle(IPermit2 permit2, address owner, address token, uint160 amount, address spender)
        internal
        view
        returns (IPermit2.PermitSingle memory permitSingle)
    {
        (,, uint48 nonce) = permit2.allowance(owner, token, spender);
        permitSingle = IPermit2.PermitSingle({
            details: IPermit2.PermitDetails({
                token: token, amount: amount, expiration: uint48(vm.getBlockTimestamp() + 1 days), nonce: nonce
            }),
            spender: spender,
            sigDeadline: vm.getBlockTimestamp() + 1 hours
        });
    }

    /// @dev Signs `permitSingle` by `key` under Permit2's domain, in the (r, s, v) layout Permit2 reads.
    function _signPermit2(IPermit2 permit2, uint256 key, IPermit2.PermitSingle memory permitSingle)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 detailsHash = keccak256(abi.encode(PERMIT2_DETAILS_TYPEHASH, permitSingle.details));
        bytes32 structHash =
            keccak256(abi.encode(PERMIT2_SINGLE_TYPEHASH, detailsHash, permitSingle.spender, permitSingle.sigDeadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
