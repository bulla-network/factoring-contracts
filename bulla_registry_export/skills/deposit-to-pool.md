# Deposit to Factoring Pool

## Description

Deposit USDC into a BullaFactoring pool (ERC4626 vault) to receive pool shares representing your proportional ownership of the fund.

## Context

-   **Repo**: factoring-contracts
-   **Contract**: BullaFactoringV2_1 (V2.1 pools) / BullaFactoringV1 (V1 pools)
-   **Networks**: Base (8453), Sepolia (11155111), Redbelly (151)

## Prerequisites

-   Caller must be whitelisted on the pool's `DepositPermissions` contract
-   Caller must have sufficient USDC balance
-   Caller must have approved the pool contract to spend their USDC

## Steps

1. Look up the pool address from `address_config.json` for the target network
2. Check deposit permission: call `depositPermissions.isAllowed(yourAddress)` on the pool
3. Approve USDC spend: call `approve(poolAddress, amount)` on the USDC token contract
4. Deposit: call `deposit(assets, receiver)` on the pool contract
    - `assets`: amount of USDC to deposit (6 decimals)
    - `receiver`: address to receive the pool shares

## Example

```solidity
// Deposit 1000 USDC into the poolAddress pool
IERC20(usdcAddress).approve(poolAddress, 1000e6);
BullaFactoringV2_1(poolAddress).deposit(1000e6, msg.sender);
```

## Common Errors

-   `UnauthorizedDeposit(address)` - Caller is not whitelisted on DepositPermissions
-   `ERC20InsufficientAllowance` - USDC approval is insufficient
-   `ERC20InsufficientBalance` - Caller does not have enough USDC
