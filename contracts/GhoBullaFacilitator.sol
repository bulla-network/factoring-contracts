// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IBullaFactoring.sol";
import "./interfaces/IGhoToken.sol";

/**
 * @title GhoBullaFacilitator
 * @notice GHO facilitator that deploys freshly minted GHO into a Bulla factoring pool.
 *
 * Following the custody model of Aave's GSM/Gsm4626 facilitators, this contract — not the
 * owner — holds the pool shares backing the GHO it has minted, so the bucket level reported
 * by the GHO token is always verifiable against collateral held at this address.
 *
 * Lifecycle:
 *  - `deposit`: deposits GHO into the pool, recycling any GHO already held by this contract
 *    and minting only the shortfall against this facilitator's bucket; the pool shares are
 *    held by this contract.
 *  - `redeem`: redeems pool shares for GHO. If the pool lacks liquidity it queues the
 *    remainder with this contract as receiver; queued payouts arrive asynchronously via the
 *    pool's redemption queue processing and are either burned by `settleGho` or recycled by
 *    the next `deposit`.
 *  - `settleGho`: burns whatever GHO this contract holds against the outstanding bucket
 *    level (permissionless), and additionally — when called by the owner — harvests any
 *    pool yield accrued above the level to the GHO treasury, leaving the bucket exactly
 *    1:1 backed.
 *
 * Requirements:
 *  - Aave governance must register this contract as a GHO facilitator with a bucket capacity.
 *  - The pool's deposit and redeem permissions must allow this contract (including at queued
 *    payout time, since the pool re-validates permissions when processing its queue).
 *  - The pool's underlying asset must be GHO.
 */
contract GhoBullaFacilitator is Ownable {
    using SafeERC20 for IERC20;

    IGhoToken public immutable gho;
    IERC4626 public immutable pool;

    /// @notice Recipient of pool yield harvested above the GHO minted by this facilitator
    address public ghoTreasury;

    /// @notice Sole address allowed to update the treasury, intended to be the Aave governance
    ///         executor (the GSM `CONFIGURATOR_ROLE` equivalent); deliberately not the owner,
    ///         so the operator can never redirect yield
    address public immutable ghoTreasuryAdmin;

    event Deposited(uint256 ghoDeposited, uint256 ghoMinted, uint256 sharesReceived);
    event GhoTreasuryUpdated(address indexed oldGhoTreasury, address indexed newGhoTreasury);
    event Redeemed(uint256 sharesRedeemed, uint256 assetsReceivedImmediately);
    event GhoSettled(uint256 ghoBurned, uint256 yieldToTreasury);

    error PoolAssetNotGho();
    error InvalidAddress();
    error CannotRescueBackingToken(address token);
    error CallerNotTreasuryAdmin(address caller);

    constructor(IGhoToken _gho, IERC4626 _pool, address _ghoTreasury, address _ghoTreasuryAdmin) Ownable(_msgSender()) {
        if (
            address(_gho) == address(0) || address(_pool) == address(0) || _ghoTreasury == address(0)
                || _ghoTreasuryAdmin == address(0)
        ) revert InvalidAddress();
        if (_pool.asset() != address(_gho)) revert PoolAssetNotGho();
        gho = _gho;
        pool = _pool;
        ghoTreasury = _ghoTreasury;
        ghoTreasuryAdmin = _ghoTreasuryAdmin;
    }

    /// @notice Updates the treasury receiving harvested yield
    /// @dev Restricted to the treasury admin (Aave governance), mirroring the GSM's
    ///      `updateGhoTreasury`; the owner cannot call this
    function updateGhoTreasury(address newGhoTreasury) external {
        if (_msgSender() != ghoTreasuryAdmin) revert CallerNotTreasuryAdmin(_msgSender());
        if (newGhoTreasury == address(0)) revert InvalidAddress();
        emit GhoTreasuryUpdated(ghoTreasury, newGhoTreasury);
        ghoTreasury = newGhoTreasury;
    }

    /// @notice Deposits `ghoAmount` GHO into the pool, recycling any GHO already held by this
    ///         contract (e.g. a landed queued-redemption payout) and minting only the shortfall
    /// @dev Held GHO is already counted in the bucket level, so redepositing it directly is
    ///      equivalent to burning and re-minting it but never touches the bucket twice.
    ///      Reverts in the GHO token if the freshly minted part would exceed the bucket capacity
    /// @return shares Pool shares received, held by this contract
    function deposit(uint256 ghoAmount) external onlyOwner returns (uint256 shares) {
        uint256 held = gho.balanceOf(address(this));
        uint256 toMint = held < ghoAmount ? ghoAmount - held : 0;
        if (toMint > 0) gho.mint(address(this), toMint);
        IERC20(address(gho)).forceApprove(address(pool), ghoAmount);
        shares = pool.deposit(ghoAmount, address(this));
        emit Deposited(ghoAmount, toMint, shares);
    }

    /// @notice Redeems pool shares for GHO, burning proceeds against the bucket level
    /// @dev If the pool lacks liquidity, the unfilled remainder is queued by the pool with this
    ///      contract as receiver; call `settleGho` once the queued payout has been processed
    /// @return assets GHO received immediately (excludes any queued remainder)
    function redeem(uint256 shares) external onlyOwner returns (uint256 assets) {
        assets = pool.redeem(shares, address(this), address(this));
        emit Redeemed(shares, assets);
        settleGho();
    }

    /// @notice Settlement: burns the GHO held by this contract against the outstanding bucket
    ///         level, then — when called by the owner — harvests pool yield accrued above the
    ///         level to the treasury
    /// @dev Burn side (permissionless): GHO only ever sits in this contract transiently
    ///      (redemption proceeds and queued payouts arriving from the pool's redemption
    ///      queue), and every unit of it is burned to deleverage the bucket before anything
    ///      else happens. The burn is capped at the level, so on a full unwind (or after
    ///      donations) the unburnable remainder is forwarded to the treasury. This doubles as
    ///      a backstop (Gsm4626 `backWithGho` equivalent): if impairment losses ever leave the
    ///      bucket under-backed, anyone can transfer GHO here and call this to burn it against
    ///      the level, re-backing the facilitator.
    ///
    ///      Harvest side (owner only): any backing above the remaining level is withdrawn from
    ///      the pool straight to the treasury. No GHO is ever minted — the treasury receives
    ///      realized GHO paid into the pool by debtors, the bucket level is untouched, and the
    ///      position stays exactly 1:1 backed afterwards. The harvest is opportunistic and
    ///      liquidity-bound: it is skipped while the pool's redemption queue is non-empty (a
    ///      withdrawal would then be queued in full — replacing any redemption this contract
    ///      already has queued — and its eventual payout would need the treasury to pass the
    ///      pool's redeem permissions), and it is capped at `pool.maxWithdraw` so nothing is
    ///      ever queued. Unharvested surplus simply stays in the pool as extra backing until
    ///      the next owner settlement.
    /// @return burned GHO burned against the bucket level
    /// @return yieldToTreasury GHO forwarded to the treasury (unburnable balance plus pool yield)
    function settleGho() public returns (uint256 burned, uint256 yieldToTreasury) {
        uint256 balance = gho.balanceOf(address(this));
        (, uint256 level) = gho.getFacilitatorBucket(address(this));
        burned = balance < level ? balance : level;
        if (burned > 0) {
            gho.burn(burned);
            level -= burned;
        }
        yieldToTreasury = balance - burned;
        if (yieldToTreasury > 0) IERC20(address(gho)).safeTransfer(ghoTreasury, yieldToTreasury);

        bool canHarvest = _msgSender() == owner() && IBullaFactoringV2_2(address(pool)).getRedemptionQueue().isQueueEmpty();
        if (canHarvest) {
            uint256 backing = pool.previewRedeem(pool.balanceOf(address(this)));
            if (backing > level) {
                uint256 surplus = backing - level;
                uint256 withdrawable = pool.maxWithdraw(address(this));
                uint256 harvested = surplus < withdrawable ? surplus : withdrawable;
                if (harvested > 0) {
                    pool.withdraw(harvested, ghoTreasury, address(this));
                    yieldToTreasury += harvested;
                }
            }
        }

        if (burned > 0 || yieldToTreasury > 0) emit GhoSettled(burned, yieldToTreasury);
    }

    /// @notice Rescues tokens accidentally sent to this contract
    /// @dev GHO and pool shares back the facilitator's bucket and cannot be rescued;
    ///      stray GHO is handled by `settleGho` instead
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(gho) || token == address(pool)) revert CannotRescueBackingToken(token);
        IERC20(token).safeTransfer(to, amount);
    }
}
