# Audit Changelog: Changes Since audited-v3

**Audit Reference Commit**: `b003dca99a9094a231988f27f1ed74cff78e8de7` (audited-v3)  
**Current HEAD Commit**: `5ffed4f`  
**Date Range**: September 1, 2025 → November 6, 2025  
**Document Generated**: November 6, 2025

---

## Executive Summary

This document details all changes made to the Bulla Factoring V2 contracts since the last audit (audited-v3). The changes include significant architectural improvements, gas optimizations, removal of deprecated features, and enhanced security measures.

### Contract Statistics

| Contract                                   | Lines Changed                | Impact Level |
| ------------------------------------------ | ---------------------------- | ------------ |
| `BullaFactoring.sol`                       | ~864 lines modified          | **HIGH**     |
| `BullaClaimV2InvoiceProviderAdapterV2.sol` | +143 additions               | **MEDIUM**   |
| `RedemptionQueue.sol`                      | ~76 lines modified           | **MEDIUM**   |
| `FeeCalculations.sol`                      | +141 additions (new library) | **HIGH**     |
| `IBullaFactoring.sol`                      | ~44 lines modified           | **MEDIUM**   |

**Total**: 9 contract files modified, 733 insertions(+), 676 deletions(-)

---

## 🔴 Critical & High-Impact Changes

### 1. **Removal of Impairment Functionality** (#171)

**Commit**: `c977e0d` | **Date**: November 4, 2025 | **Impact**: HIGH

**Description**: Completely removed the pool-level invoice impairment system and its related state management.

**Changes**:

-   Removed `impairInvoice()` function
-   Removed impairment-related events and errors
-   **However**: Pool owner can now unfactor impaired invoices (see #172)

**Rationale**: Impairment functionality moved to the underlying Bulla Claim contracts, eliminating duplication and complexity.

---

### 2. **O(1) Accrued Interest Calculation** (#169)

**Commit**: `2a098bd` | **Date**: November 3, 2025 | **Impact**: HIGH

**Description**: Replaced iterative accrued interest calculations with constant-time aggregate tracking.

**Changes**:

-   Introduced aggregate state tracking variables:
    -   `totalDailyInterestRateSum`: Sum of all active invoice daily interest rates
    -   `fundedInvoicesCount`: Count of active funded invoices
    -   `lastAccruedCalculationTimestamp`: Last calculation checkpoint
-   New functions:
    -   `_addInvoiceToAggregate()`: Adds invoice to aggregate tracking
    -   `_removeInvoiceFromAggregate()`: Removes invoice from aggregate tracking
-   Modified `calculateAccruedProfits()` to use O(1) calculation instead of O(n) iteration

**Gas Impact**:

-   **Before**: O(n) gas cost, scales linearly with active invoices
-   **After**: O(1) gas cost, constant regardless of invoice count
-   Estimated savings: ~50,000+ gas for pools with 10+ active invoices

**Testing**: Existing tests verify accuracy matches previous implementation.

---

### 3. **Protocol Fee Model Change** (#158)

**Commit**: `fa9314f` | **Date**: October 15, 2025 | **Impact**: HIGH

**Description**: Changed protocol fee collection from reconciliation-time to funding-time.

**Changes**:

-   Protocol fee now deducted immediately when invoice is funded
-   Fee withheld from `fundedAmountNet` sent to factorer
-   Protocol fee added to `protocolFeeBalance` at funding time
-   Protocol fee included in `capitalAtRiskPlusWithheldFees` tracking
-   Updated unfactoring logic to handle withheld protocol fees
-   Modified `FeeCalculations` library to calculate protocol fee upfront

**Accounting Impact**:

```solidity
// OLD: Protocol fee collected at reconciliation
fundedAmountNet = fundedAmountGross - adminFee - interestFee

// NEW: Protocol fee withheld at funding
fundedAmountNet = fundedAmountGross - adminFee - interestFee - protocolFee
protocolFeeBalance += protocolFee
capitalAtRiskPlusWithheldFees += fundedAmountGross + protocolFee
```

---

### 4. **Automatic Redemption Queue Processing** (#175)

**Commit**: `4ffea09` | **Date**: November 6, 2025 | **Impact**: HIGH

**Description**: Automatically process pending redemptions when liquidity becomes available.

**Changes**:

-   Changed `processRedemptionQueue()` visibility from `external` to `public`
-   Added automatic `processRedemptionQueue()` call in:
    -   `deposit()` - After new liquidity is added
    -   `reconcileSingleInvoice()` - After capital returns from paid invoice
    -   `unfactorInvoice()` - After capital returns to pool
-   Ensures immediate processing of queued redemptions without manual intervention

### 5. **Pool Owner Unfactoring of Impaired Invoices** (#172)

**Commit**: `90b382e` | **Date**: November 5, 2025 | **Impact**: HIGH

**Description**: Allows pool owner to unfactor impaired invoices (previously only original creditor could unfactor).

**Changes**:

-   Modified `unfactorInvoice()` to check caller:
    -   If pool owner: Can only unfactor impaired invoices
    -   If original creditor: Can unfactor anytime
-   Replaced impairment system removed in #171
-   Uses BullaClaim contract's impairment status instead of pool's grace period
-   Added `previewUnfactor()` function for off-chain simulation
-   Returns refund calculation: `(int256 totalRefundOrPaymentAmount, uint256 trueInterest, uint256 trueSpreadAmount, uint256 trueAdminFee)`

### 6. **Redemption Queue Length Limit** (#174)

**Commit**: `9d7718e` | **Date**: November 6, 2025 | **Impact**: MEDIUM-HIGH

**Description**: Adds configurable maximum length limit to redemption queue to prevent DoS.

**Changes**:

-   Added `maxQueueLength` state variable in `RedemptionQueue.sol`
-   Added `setMaxQueueLength()` function (owner only)
-   Modified `queueRedemption()` to check and revert if limit reached
-   New error: `error QueueLengthLimitReached(uint256 limit);`
-   New event: `event MaxQueueLengthUpdated(uint256 newLimit);`
-   Updated `getQueueLength()` to return current and max length

### 7. **Invoice Paid Callbacks Integration** (#167)

**Commit**: `c05ff53` | **Date**: October 31, 2025 | **Impact**: MEDIUM

**Description**: Integrates with BullaClaim's callback system to be notified when invoices are paid.

**Changes**:

-   Added `_registerInvoiceCallback()` internal function
-   Registers the factoring pool as a callback recipient on funded invoices
-   Enables automatic notification when debtors pay invoices
-   Simplifies reconciliation trigger mechanism

## 🟡 Medium-Impact Changes

### 8. **Pagination for `viewPoolStatus()`** (#173)

**Commit**: `608ee3f` | **Date**: November 5, 2025

**Description**: Added pagination to prevent gas limit issues when viewing pool status with many active invoices.

**Changes**:

-   Modified `viewPoolStatus()` signature:
    -   Before: `viewPoolStatus() returns (uint256[] impairedInvoiceIds)`
    -   After: `viewPoolStatus(uint256 offset, uint256 limit) returns (uint256[] impairedInvoiceIds, bool hasMore)`
-   Added `offset` and `limit` parameters
-   Returns `hasMore` flag to indicate additional pages
-   Limit capped at 25,000 invoices per call

---

### 9. **Default Redeem/Withdraw with Queueing** (#153)

**Commit**: `21327eb` | **Date**: October 9, 2025

**Description**: Changed default `redeem()` and `withdraw()` to automatically queue excess amounts instead of reverting.

**Changes**:

-   `redeem()` now automatically queues shares that cannot be immediately redeemed
-   `withdraw()` now automatically queues assets that cannot be immediately withdrawn
-   Removed separate `redeemAndOrQueue()` and `withdrawAndOrQueue()` functions (logic merged)
-   Simplifies user experience - single function handles both cases

**Behavior**:

```solidity
// Before: Would revert if insufficient liquidity
redeem(100 shares) → REVERT

// After: Partially redeems and queues the rest
redeem(100 shares) → Redeems 40 shares immediately, queues 60 shares
```

---

### 10. **Removal of Auto-Reconciliation** (#155)

**Commit**: `993f85a` | **Date**: October 10, 2025

**Description**: Removed automatic reconciliation of paid invoices on various operations.

**Changes**:

-   Removed `reconcileActivePaidInvoices()` internal calls from:
    -   `redeem()`
    -   `withdraw()`
    -   `fundInvoice()`
-   Reconciliation now only happens via explicit `reconcileSingleInvoice()` calls
-   Simplifies transaction flows
-   Reduces gas costs for non-reconciliation operations

**Rationale**: With callback integration (#167), reconciliation can be triggered externally by automation rather than automatically on every operation.

---

### 11. **Fee Calculations Library Extraction** (#154)

**Commit**: `0af9615` | **Date**: October 9, 2025

**Description**: Extracted fee calculation logic into separate library to reduce main contract size.

**Changes**:

-   Created new `contracts/libraries/FeeCalculations.sol` (+144 lines)
-   Moved fee calculation functions to library:
    -   `calculateTargetFees()`
    -   `calculateKickbackAmount()`
-   Reduced `BullaFactoring.sol` by ~93 lines
-   Improves code organization and reusability

---

### 12. **Merge Spread Gains with Admin Fee** (#156)

**Commit**: `a5fd527` | **Date**: October 10, 2025

**Description**: Simplified fee tracking by merging spread gains into admin fee balance.

**Changes**:

-   Removed separate `spreadGainsBalance` tracking
-   Spread amounts now added to `adminFeeBalance`
-   Simplified `withdrawAdminFeesAndSpreadGains()` function
-   Reduces state variables and storage operations

---

### 13. **Removal of `minDays` Parameter** (#168)

**Commit**: `5ea01ab` | **Date**: November 3, 2025

**Description**: Removed `minDays` parameter from `approveInvoice()` function.

**Changes**:

-   Function signature changed:
    -   Before: `approveInvoice(invoiceId, targetYieldBps, spreadBps, upfrontBps, minDays, initialInvoiceValueOverride)`
    -   After: `approveInvoice(invoiceId, targetYieldBps, spreadBps, upfrontBps, initialInvoiceValueOverride)`
-   Simplified approval logic
-   Reduces gas costs for approvals

---

### 14. **At-Risk Capital Balance Tracking** (#170)

**Commit**: `de1f1f9` | **Date**: November 3, 2025

**Description**: Replaced iterative capital-at-risk calculation with tracked balance.

**Changes**:

-   Introduced `capitalAtRiskPlusWithheldFees` state variable
-   Updated on:
    -   Invoice funding: `+= (fundedAmountGross + protocolFee)`
    -   Invoice reconciliation: `-= (fundedAmountGross + protocolFee)`
    -   Invoice unfactoring: `-= (fundedAmountGross + protocolFee)`
-   Eliminates need to iterate over active invoices
-   Works in conjunction with O(1) accrued interest (#169)

**Gas Impact**:

-   Converts O(n) operation to O(1)
-   Significant savings for pools with many active invoices

---

## 🟢 Low-Impact & Optimization Changes

### 15. **Storage/Memory Access Optimization** (#165)

**Commit**: `90119c7` | **Date**: October 30, 2025

**Description**: Optimized storage and memory access patterns to reduce gas costs.

**Changes**:

-   Reduced SLOAD operations by caching frequently accessed storage variables
-   Optimized struct access patterns
-   Improved memory usage in loops

---

### 16. **Struct Packing** (#163)

**Commit**: `42e8c73` | **Date**: October 27, 2025

**Description**: Optimized struct layouts to reduce storage slots and gas costs.

**Changes**:

-   Reordered struct fields for optimal packing
-   Reduced storage slot usage
-   Gas savings on struct reads/writes

---

### 17. **Invoice Details Fetch Optimization** (#152, #161)

**Commits**: `c9df83a`, `44d957d` | **Dates**: October 8, 23, 2025

**Description**: Optimized when and how invoice details are fetched from adapter.

**Changes**:

-   Moved `getInvoiceDetails()` calls to only when needed
-   Cached invoice details in memory
-   Reduced external calls

---

### 18. **Accrued Calculations Simplification** (#166)

**Commit**: `c42cf96` | **Date**: October 31, 2025

**Description**: Simplified accrued profit calculations for clarity and gas efficiency.

---

### 19. **Remove Unused Code** (#157)

**Commit**: `3aa5969` | **Date**: October 10, 2025

**Description**: Removed unused functions, events, and variables to reduce contract size.

---

## 🔍 Files Modified Summary

### Core Contract Files

-   ✅ `contracts/BullaFactoring.sol` - **SIGNIFICANT CHANGES**
-   ✅ `contracts/BullaClaimV2InvoiceProviderAdapterV2.sol` - **ADDITIONS**
-   ✅ `contracts/RedemptionQueue.sol` - **MODERATE CHANGES**
-   ✅ `contracts/libraries/FeeCalculations.sol` - **NEW FILE**
-   ✅ `contracts/interfaces/IBullaFactoring.sol` - **SIGNATURE CHANGES**
-   ✅ `contracts/interfaces/IRedemptionQueue.sol` - **ADDITIONS**
-   ✅ `contracts/interfaces/IInvoiceProviderAdapter.sol` - **MINOR CHANGES**
-   🗑️ `contracts/BullaClaimV1InvoiceProviderAdapterV2.sol` - **DELETIONS**

---

## 📋 Commit-by-Commit Summary

<details>
<summary>Click to expand full commit list (27 commits)</summary>

1. **`5ffed4f`** - feat: add missing tests (Nov 6, 2025)
2. **`4ffea09`** - feat: add automatic processing to pay claim, deposit and unfactor (#175)
3. **`9d7718e`** - feat: add redemption queue length limit (#174)
4. **`608ee3f`** - feat: add pagination to viewPoolStatus (#173)
5. **`90b382e`** - feat: allow pool owner to unfactor invoice (#172)
6. **`c977e0d`** - feat: remove impairment functionality (#171)
7. **`de1f1f9`** - feat: use at risk capital balance instead of iteration (#170)
8. **`2a098bd`** - feat: implement O(1) solution for accrued interest (#169)
9. **`5ea01ab`** - feat: remove minDays from approveInvoice (#168)
10. **`c05ff53`** - feat: incorporate paid callbacks (#167)
11. **`c42cf96`** - feat: simplify accured calculations (#166)
12. **`90119c7`** - feat: improve storage/memory access to optimize reads (#165)
13. **`2b664bb`** - Solidoracle/dev-2259-deployment-scripts-for-reconciliation-automation-in-gelato (#164)
14. **`42e8c73`** - feat: pack structs (#163)
15. **`941137b`** - feat: deploy latest 2_1 version (#162)
16. **`44d957d`** - feat: move impairment checks locally and move getInvoiceDetails only when needed (#161)
17. **`45cdb3b`** - feat: deploy new sep pool 2 1 (#160)
18. **`76a659c`** - feat: 2.1 deployment sepolia (#159)
19. **`fa9314f`** - feat: change protocol fee to be on factor, captured immediately (#158)
20. **`3aa5969`** - feat: remove more unused stuff (#157)
21. **`a5fd527`** - feat: merge spread gains with admin fee, do not track individual gains (#156)
22. **`993f85a`** - feat: remove auto reconciliation (#155)
23. **`0af9615`** - feat: liberate space by moving fee calculations to libary (#154)
24. **`21327eb`** - feat: add queueing to default redeem/withdraw (#153)
25. **`c9df83a`** - feat: optimize gas around invoice details fetch (#152)
26. **`c439044`** - feat: deploy TCS V2 pool, add whitelisting and setImpairReserve scripts (#151)
27. **`d790613`** - fix: typechain file generation (#150)
28. **`a7d59a7`** - feat: deploy fundora V2 test (#149)

</details>

---

_End of Audit Changelog_
