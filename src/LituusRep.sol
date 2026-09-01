// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { ILituusRep } from "./interfaces/ILituusRep.sol";

/// @notice Lituus REP (wREP): a share token over an underlying Zoltar REP vault.
/// @dev See ILituusRep for the accounting model. In short: a stored assets-per-share rate that
///      moves only in burnShares and only upward; amounts leaving the vault round down and amounts
///      entering round up (always in the vault's favor); assets are tracked in an internal ledger
///      so direct underlying transfers are inert; and the rate persists through an emptied vault.
///      All mutations are owner-only (the Multiverse) - the vault exposes no public deposit/redeem
///      surface. The underlying is assumed to be a standard ERC20 (no transfer fees, no rebasing,
///      no hooks).
contract LituusRep is ERC20, Ownable, ReentrancyGuard, ILituusRep {
    using SafeERC20 for IERC20;

    /* =========================================== CONSTANTS/IMMUTABLES ========================================== */

    /// @notice Fixed-point scale of the exchange rate (1e18).
    uint256 public constant SCALE = 1 ether;

    /// @notice The underlying Zoltar REP token this vault wraps.
    IERC20 public immutable UNDERLYING_TOKEN;

    /* ================================================ VARIABLES ================================================ */

    /// @inheritdoc ILituusRep
    uint256 public rate;

    /// @inheritdoc ILituusRep
    uint256 public totalAssets;

    /// @inheritdoc ILituusRep
    bool public unwrapPaused;

    /* ================================================== ERRORS ================================================= */

    error ZeroShares();
    error ZeroAssets();
    error ZeroRate();
    error UnwrapIsPaused();

    /* =============================================== CONSTRUCTOR =============================================== */

    /// @param owner The Multiverse: the only account allowed to mutate the vault.
    /// @param underlyingToken The Zoltar REP token wrapped by this vault.
    /// @param name The ERC20 name of the share token.
    /// @param symbol The ERC20 symbol of the share token.
    /// @param initialRate The starting assets-per-share rate (1e18-scaled): SCALE for a genesis
    /// universe, the parent vault's rate for a child spawned at a fork, so accrued appreciation
    /// carries across universes.
    constructor(address owner, address underlyingToken, string memory name, string memory symbol, uint256 initialRate)
        ERC20(name, symbol)
        Ownable(owner)
    {
        if (initialRate == 0) revert ZeroRate();
        UNDERLYING_TOKEN = IERC20(underlyingToken);
        rate = initialRate;
    }

    /* ============================================== WRAP FUNCTIONS ============================================= */

    /// @inheritdoc ILituusRep
    function wrap(address sender, uint256 assets) external onlyOwner nonReentrant returns (uint256 shares) {
        shares = convertToShares(assets);
        if (shares == 0) revert ZeroShares();

        UNDERLYING_TOKEN.safeTransferFrom(sender, address(this), assets);
        totalAssets += assets;
        _mint(sender, shares);

        emit Wrapped(sender, assets, shares);
    }

    /// @inheritdoc ILituusRep
    function wrapShares(address sender, uint256 shares) external onlyOwner nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        assets = convertToAssetsUp(shares);

        UNDERLYING_TOKEN.safeTransferFrom(sender, address(this), assets);
        totalAssets += assets;
        _mint(sender, shares);

        emit Wrapped(sender, assets, shares);
    }

    /* ============================================= UNWRAP FUNCTIONS ============================================ */

    /// @inheritdoc ILituusRep
    function unwrap(address sender, uint256 shares) external onlyOwner nonReentrant returns (uint256 assets) {
        if (unwrapPaused) revert UnwrapIsPaused();
        assets = convertToAssets(shares);
        if (assets == 0) revert ZeroAssets();

        _burn(sender, shares);
        totalAssets -= assets;
        UNDERLYING_TOKEN.safeTransfer(sender, assets);

        emit Unwrapped(sender, shares, assets);
    }

    /// @inheritdoc ILituusRep
    function unwrapAssets(address sender, uint256 assets) external onlyOwner nonReentrant returns (uint256 shares) {
        if (unwrapPaused) revert UnwrapIsPaused();
        if (assets == 0) revert ZeroAssets();
        shares = convertToSharesUp(assets);

        _burn(sender, shares);
        totalAssets -= assets;
        UNDERLYING_TOKEN.safeTransfer(sender, assets);

        emit Unwrapped(sender, shares, assets);
    }

    /* ============================================== BURN FUNCTIONS ============================================= */

    /// @inheritdoc ILituusRep
    function burnShares(uint256 shares) external onlyOwner {
        _burn(msg.sender, shares);

        // The asset ledger is untouched, so fewer shares back the same assets: the rate can only
        // rise. Rounding remainders retained by past wraps and unwraps fold into the recomputed
        // rate here, socializing them across all remaining holders. When the burn empties the
        // supply the recompute is skipped and the previous rate persists, so a vault regrown from
        // zero keeps its accrued appreciation.
        uint256 supply = totalSupply();
        if (supply > 0) {
            rate = totalAssets * SCALE / supply;
        }

        emit SharesBurned(shares, rate);
    }

    /* ============================================== ADMIN FUNCTIONS ============================================ */

    /// @inheritdoc ILituusRep
    function setUnwrapPaused(bool paused) external onlyOwner {
        unwrapPaused = paused;
        emit UnwrapPauseSet(paused);
    }

    /* =============================================== VIEW FUNCTIONS ============================================ */

    /// @inheritdoc ILituusRep
    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        return assets * SCALE / rate;
    }

    /// @inheritdoc ILituusRep
    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        return shares * rate / SCALE;
    }

    /// @inheritdoc ILituusRep
    function convertToSharesUp(uint256 assets) public view returns (uint256 shares) {
        return (assets * SCALE + rate - 1) / rate;
    }

    /// @inheritdoc ILituusRep
    function convertToAssetsUp(uint256 shares) public view returns (uint256 assets) {
        return (shares * rate + SCALE - 1) / SCALE;
    }
}
