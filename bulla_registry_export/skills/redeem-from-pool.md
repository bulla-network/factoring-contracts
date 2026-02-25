# Redeem from Factoring Pool

## Description

Redeem pool shares from a BullaFactoring pool to withdraw USDC. If the pool has insufficient liquidity, excess shares are automatically queued for future redemption via the RedemptionQueue.

## Context

-   **Repo**: factoring-contracts
-   **Contract**: BullaFactoringV2_1 (V2.1 pools) / BullaFactoringV1 (V1 pools)
-   **Networks**: Base (8453), Sepolia (11155111), Redbelly (151)

## Prerequisites

-   Caller must be whitelisted on the pool's `RedeemPermissions` contract
-   Caller (or owner) must hold pool shares

## Steps

1. Look up the pool address from `address_config.json` for the target network
2. Check max redeemable shares: call `maxRedeem(owner)` on the pool — this returns the lesser of the owner's share balance and available pool liquidity
3. Preview redemption value: call `previewRedeem(shares)` to see expected USDC output
4. Redeem: call `redeem(shares, receiver, owner)` on the pool contract
    - `shares`: number of pool shares to redeem
    - `receiver`: address to receive the USDC
    - `owner`: address that owns the shares
    - **Return value**: the amount of USDC assets redeemed immediately (0 if everything was queued)
5. Check the transaction events to understand what happened:
    - `Withdraw(sender, receiver, owner, assets, shares)` — emitted from the pool for shares redeemed immediately
    - In V2.1 pools: if shares are queued due to insufficient liquidity, a `RedemptionQueued(owner, receiver, shares, assets, queueIndex)` event is emitted from the pool's **RedemptionQueue** contract (not the pool itself) with the amount of shares queued. Queued redemptions are processed automatically when new deposits or invoice repayments add liquidity, emitting `RedemptionProcessed` from the RedemptionQueue

## Example

```solidity
// Redeem the maximum available shares from a pool
uint256 shares = BullaFactoringV2_1(poolAddress).maxRedeem(msg.sender);
uint256 redeemedAssets = BullaFactoringV2_1(poolAddress).redeem(shares, msg.sender, msg.sender);

// redeemedAssets = USDC received immediately
// If shares > maxRedeem, the excess is queued — check for RedemptionQueued event
// queuedShares = requestedShares - redeemedShares
```

## Common Errors

-   `UnauthorizedRedeem(address)` - Caller or owner is not whitelisted on RedeemPermissions
-   `ERC20InsufficientBalance` - Owner does not have enough shares
