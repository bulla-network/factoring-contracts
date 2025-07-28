# Bulla Factoring V2 & Redemption Queue - Audit Scope

## Executive Summary

This audit scope covers the BullaFactoringV2 contract and its associated RedemptionQueue contract, which together implement a sophisticated invoice factoring fund with ERC4626 compatibility and advanced liquidity management capabilities.

## Contracts in Scope

### Primary Contracts

1. **BullaFactoringV2.sol** - Main factoring fund contract
2. **RedemptionQueue.sol** - FIFO redemption queue manager

### Interface Contracts

3. **IBullaFactoring.sol** - Main contract interface
4. **IRedemptionQueue.sol** - Queue contract interface
5. **IInvoiceProviderAdapter.sol** - Invoice provider integration interface

## System Architecture Overview

### BullaFactoringV2 Contract

-   **Type**: ERC4626 Vault with invoice factoring capabilities
-   **Core Function**: Pools investor funds to factor invoices for yield generation
-   **Key Features**:
    -   Invoice approval and funding workflows
    -   Integration with BullaFrendLend for loan offers
    -   Dynamic fee calculation and distribution
    -   Asset price calculations with accrued profits
    -   Impairment management system
    -   Redemption queue integration for liquidity management

### RedemptionQueue Contract

-   **Type**: FIFO queue manager for redemption requests
-   **Core Function**: Handles redemption requests when insufficient vault liquidity exists
-   **Key Features**:
    -   Share-based and asset-based redemption queuing
    -   Head pointer optimization for efficient queue operations
    -   Partial redemption processing
    -   Queue compaction functionality

## Dependencies & External Contracts

### External Protocol Dependencies

-   **OpenZeppelin Contracts**: ERC20, ERC4626, ERC721, Ownable, SafeERC20
-   **BullaFrendLend**: Loan offering and management
-   **Invoice Provider Adapters**: Invoice data and state management

### Network Dependencies

-   **Bulla Claim Contracts**: Invoice/Receivable tokenization
-   **ERC20 Token Contracts**: Underlying asset (USDC, etc.)
